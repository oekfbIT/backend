/**
 * Standalone worker (DigitalOcean): polls the backend for queued Veo jobs (admin button with
 * VEO_SYNC_MODE=queue), runs each as its own process (`index.mjs match …`), streams the log back.
 * Optional: nightly import of all new library recordings (VEO_SYNC_NIGHTLY_HOUR, Europe/Vienna).
 */
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { backend } from "./backend.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const POLL_MS = Number(process.env.VEO_SYNC_POLL_SECONDS || 15) * 1000;
const NIGHTLY_HOUR = process.env.VEO_SYNC_NIGHTLY_HOUR; // e.g. "3" → 03:00 Vienna; empty = off
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let current = null; // { jobId, child }

function run(args, onLines) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(here, "index.mjs"), ...args], { env: process.env, cwd: path.resolve(here, "..") });
    if (current) current.child = child;
    let partial = "";
    const handle = (chunk) => {
      const text = partial + chunk.toString();
      const lines = text.split("\n");
      partial = lines.pop();
      if (lines.length) onLines(lines.filter((l) => l.trim()));
    };
    child.stdout.on("data", handle);
    child.stderr.on("data", handle);
    child.on("close", (code) => { if (partial.trim()) onLines([partial]); resolve(code ?? 1); });
  });
}

async function runJob(job) {
  console.log(`Job ${job.id}: Spiel ${job.match_id}${job.veo_slug ? ` (${job.veo_slug})` : ""}`);
  current = { jobId: job.id, child: null };
  let buffer = [];
  const flush = async (status) => {
    const lines = buffer; buffer = [];
    if (!lines.length && !status) return;
    await backend.jobLog(job.id, lines, status).catch((e) => console.error(`Log senden fehlgeschlagen: ${e.message}`));
  };
  const timer = setInterval(() => flush(), 3000);
  const args = ["match", job.match_id];
  if (job.veo_slug) args.push("--slug", job.veo_slug);
  if (!job.with_video) args.push("--no-video");
  const code = await run(args, (lines) => { lines.forEach((l) => console.log(`  ${l}`)); buffer.push(...lines); });
  clearInterval(timer);
  buffer.push(code === 0 ? "✓ Fertig" : `✗ Beendet mit Code ${code}`);
  await flush(code === 0 ? "completed" : "failed");
  current = null;
}

async function nightlyDue(state) {
  if (NIGHTLY_HOUR === undefined || NIGHTLY_HOUR === "") return false;
  const now = new Date(new Date().toLocaleString("en-US", { timeZone: "Europe/Vienna" }));
  const today = now.toISOString().slice(0, 10);
  if (now.getHours() === Number(NIGHTLY_HOUR) && state.lastNightly !== today) { state.lastNightly = today; return true; }
  return false;
}

// Container stop / redeploy: mark the running job as failed so the admin can start it again.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, async () => {
    if (current) {
      current.child?.kill("SIGTERM");
      await backend.jobLog(current.jobId, ["✗ Worker wurde neu gestartet – bitte erneut starten"], "failed").catch(() => {});
    }
    process.exit(0);
  });
}

export async function startWorker() {
  console.log(`Veo-Worker gestartet (Backend ${process.env.VEO_SYNC_BACKEND_URL}, alle ${POLL_MS / 1000} s${NIGHTLY_HOUR ? `, nächtlicher Import ${NIGHTLY_HOUR}:00` : ""})`);
  const state = {};
  for (;;) {
    try {
      const job = await backend.claimJob();
      if (job) { await runJob(job); continue; }
      if (await nightlyDue(state)) {
        console.log("Nächtlicher Import…");
        await run(["sync"], (lines) => lines.forEach((l) => console.log(`  ${l}`)));
      }
    } catch (error) {
      console.error(`Worker-Fehler: ${error.message}`);
    }
    await sleep(POLL_MS);
  }
}
