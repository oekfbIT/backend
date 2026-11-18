import fs from "node:fs/promises";
import path from "node:path";
import { config } from "./config.mjs";
import { openVeo, ensureLoggedIn, listRecordings, captureMatch, downloadRecording } from "./veo.mjs";
import { findEvents, findStats, normaliseTeams, parseDate, durationSeconds } from "./parse.mjs";
import { upload, faststart, cutClip } from "./media.mjs";
import { backend } from "./backend.mjs";

/**
 * npm run discover -- <slug>   save all JSON the Veo editor loads for one match (to write the parsers)
 * npm run sync                 import every recording that is not completed yet (max VEO_SYNC_MAX_PER_RUN)
 * npm run sync:one -- <slug>   import one recording
 * Add --no-video to import only data (no download/upload/clips).
 */
const [mode = "sync", ...args] = process.argv.slice(2);
const only = args.includes("--only") ? args[args.indexOf("--only") + 1] : (mode === "discover" ? args[0] : null);
const withVideo = !args.includes("--no-video");
const forcedSlug = args.includes("--slug") ? args[args.indexOf("--slug") + 1] : null;
let forcedMatchId = null;

const veo = await openVeo();
try {
  await ensureLoggedIn(veo);

  if (mode === "discover") {
    if (!only) throw new Error("Usage: npm run discover -- <veo-slug>");
    const captured = await captureMatch(veo, only);
    const dir = path.join(config.paths.captures, only);
    await fs.mkdir(dir, { recursive: true });
    for (const [i, entry] of captured.entries()) {
      await fs.writeFile(path.join(dir, `${String(i).padStart(3, "0")}.json`), JSON.stringify(entry, null, 2));
    }
    console.log(`Saved ${captured.length} responses to ${dir}`);
    console.log(`Heuristic found ${findEvents(captured).length} events, stats: ${JSON.stringify(findStats(captured))}`);
  } else if (mode === "match") {
    // Admin trigger: find (or use the given) Veo recording for one ÖKFB match and import it.
    forcedMatchId = args[0];
    if (!forcedMatchId) throw new Error("Usage: node src/index.mjs match <matchId> [--slug <slug>] [--no-video]");
    const info = await backend.matchInfo(forcedMatchId);
    console.log(`Spiel: ${info.home_name} – ${info.away_name} (${info.date ?? "kein Datum"})`);
    const library = await listRecordings(veo);
    console.log(`Veo-Bibliothek: ${library.length} Aufnahmen`);
    let pick = forcedSlug ? (library.find((r) => r.slug === forcedSlug) ?? { slug: forcedSlug, title: forcedSlug }) : bestCandidate(library, info);
    if (!pick) throw new Error("Keine passende Veo-Aufnahme gefunden – bitte Veo-Link einfügen.");
    console.log(`Gewählt: ${pick.title} (${pick.slug})`);
    await importRecording(pick, (await backend.known()).find((k) => k.veo_slug === pick.slug));
  } else {
    const library = await listRecordings(veo);
    const known = new Map((await backend.known()).map((k) => [k.veo_slug, k]));
    const todo = library
      .filter((r) => (only ? r.slug === only : known.get(r.slug)?.status !== "completed"))
      .slice(0, only ? 1 : config.maxPerRun);
    console.log(`Library: ${library.length} recordings, ${todo.length} to import`);

    for (const recording of todo) {
      try {
        await importRecording(recording, known.get(recording.slug));
      } catch (error) {
        console.error(`✗ ${recording.slug}: ${error.message}`);
      }
    }
  }
} finally {
  await veo.browser.close();
}

async function importRecording(recording, known) {
  console.log(`→ ${recording.slug} (${recording.title})`);

  // 1) Data from all tabs.
  const captured = await captureMatch(veo, recording.slug);
  // Keep every capture on disk so the parsers can be written against Veo's real data.
  const dir = path.join(config.paths.captures, recording.slug);
  await fs.mkdir(dir, { recursive: true });
  for (const [i, entry] of captured.entries()) await fs.writeFile(path.join(dir, `${String(i).padStart(3, "0")}.json`), JSON.stringify(entry, null, 2));
  console.log(`  Rohdaten gespeichert: tools/veo-sync/captures/${recording.slug}/`);
  const events = normaliseTeams(findEvents(captured));
  const summary = await backend.upsertRecording({
    veo_slug: recording.slug,
    title: recording.title,
    recorded_at: parseDate(recording.dateText),
    duration_seconds: durationSeconds(recording.durationText),
    events,
    match_id: forcedMatchId ?? undefined,
    stats: findStats(captured),
    // Keep the raw responses (truncated) for debugging and future parsers.
    raw: Object.fromEntries(captured.slice(0, 40).map((c, i) => [String(i), JSON.stringify(c).slice(0, 20000)])),
  });
  console.log(`  ${events.length} events, status ${summary.status}${summary.review_notes ? ` – ${summary.review_notes.join("; ")}` : ""}`);
  if (!withVideo || !summary.match_id) return;

  // 2) Full recording → Spaces CDN.
  let videoFile;
  if (!known?.has_video) {
    videoFile = await faststart(await downloadRecording(veo, recording.slug));
    const url = await upload(videoFile, `matches/${summary.match_id}/recording.mp4`, "video/mp4");
    await backend.setVideo(recording.slug, url);
    console.log(`  video → ${url}`);
  } else {
    videoFile = path.join(config.paths.downloads, `${recording.slug}.web.mp4`);
    if (!(await fs.access(videoFile).then(() => true, () => false))) return; // clips need the local file
  }

  // 3) Highlights cut from the full recording (10 s before, 6 s after), uploaded with thumbnails.
  const clips = [];
  for (const event of events.filter((e) => config.clipTypes.includes(e.type))) {
    const start = Math.max(0, event.video_second - config.clipBefore), end = event.video_second + config.clipAfter;
    const name = `${event.type}-${Math.round(event.video_second)}`;
    const files = await cutClip(videoFile, { start, end, event: event.video_second }, path.join(config.paths.downloads, recording.slug), name);
    clips.push({
      veo_event_id: event.veo_id, type: event.type, event_second: event.video_second, start_second: start, end_second: end,
      video_url: await upload(files.clip, `matches/${summary.match_id}/clips/${name}.mp4`, "video/mp4"),
      thumbnail_url: await upload(files.thumb, `matches/${summary.match_id}/clips/${name}.jpg`, "image/jpeg"),
    });
  }
  if (clips.length) await backend.addClips(recording.slug, clips);
  console.log(`  ${clips.length} clips uploaded`);
}

function norm(s) { return (s ?? "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim(); }
function overlap(a, b) {
  const A = new Set(norm(a).split(" ").filter((w) => w.length > 2)), B = new Set(norm(b).split(" ").filter((w) => w.length > 2));
  if (!A.size || !B.size) return 0;
  let n = 0; for (const w of A) if (B.has(w)) n++;
  return n / Math.min(A.size, B.size);
}
function bestCandidate(library, info) {
  const target = info.date ? new Date(info.date) : null;
  const scored = library.map((r) => {
    const d = parseDate(r.dateText);
    const days = target && d ? Math.abs(new Date(d) - target) / 86400000 : 99;
    const score = overlap(r.title, info.home_name) + overlap(r.title, info.away_name) + (days <= 1.5 ? 1 : days <= 3 ? 0.3 : 0);
    return { r, score, days };
  }).sort((a, b) => b.score - a.score);
  for (const c of scored.slice(0, 5)) console.log(`  Kandidat ${c.score.toFixed(2)} | ${c.r.title} | ${c.r.dateText ?? "?"}`);
  return scored[0] && scored[0].score >= 1.2 ? scored[0].r : null;
}
