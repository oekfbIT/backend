import fs from "node:fs/promises";
import path from "node:path";
import { config } from "./config.mjs";
import { openVeo, ensureLoggedIn, listRecordings, captureMatch, downloadRecording } from "./veo.mjs";
import { findEvents, findStats, normaliseTeams, parseDate, durationSeconds } from "./parse.mjs";
import { upload, faststart, checkFfmpeg } from "./media.mjs";
import { parseVeo } from "./veoData.mjs";
import { downloadFile, cookieHeader } from "./download.mjs";
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

// Never hang forever: stop the whole run after 60 minutes (a full download + clips takes far less).
setTimeout(() => { console.error("✗ Abbruch nach 60 Minuten (Zeitlimit)"); process.exit(2); }, 60 * 60 * 1000).unref();
process.on("unhandledRejection", (e) => { console.error(`✗ ${e?.message ?? e}`); process.exit(1); });

// ffmpeg is optional now (Veo delivers clips ready-made); only used to optimise the full video for streaming.
const hasFfmpeg = await checkFfmpeg().then(() => true, () => false);
const veo = await openVeo();
try {
  await ensureLoggedIn(veo);

  if (mode === "discover") {
    if (!only) throw new Error("Usage: npm run discover -- <veo-slug>");
    const dir = path.join(config.paths.captures, only);
    await fs.mkdir(dir, { recursive: true });
    const { captured, panels } = await captureMatch(veo, only, dir);
    await fs.writeFile(path.join(dir, "panels.json"), JSON.stringify(panels, null, 2));
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
    await importRecording(pick, (await backend.known()).find((k) => k.veo_slug === pick.slug), info);
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

async function importRecording(recording, known, info) {
  console.log(`→ ${recording.slug} (${recording.title})`);

  // 1) Read every panel; keep the raw data on disk for debugging.
  const dir = path.join(config.paths.captures, recording.slug);
  await fs.mkdir(dir, { recursive: true });
  const { captured, panels } = await captureMatch(veo, recording.slug, dir);
  for (const [i, entry] of captured.entries()) await fs.writeFile(path.join(dir, `${String(i).padStart(3, "0")}.json`), JSON.stringify(entry, null, 2));
  await fs.writeFile(path.join(dir, "panels.json"), JSON.stringify(panels, null, 2));

  const data = parseVeo(captured, info?.score);
  const count = (t) => data.events.filter((e) => e.type === t).length;
  console.log(`  Veo: ${count("goal")} Tore, ${count("shot")} Schüsse, ${data.events.length} Ereignisse, ${data.highlights.length} Veo-Clips`);
  console.log(`  ${data.orientationNote}`);
  if (data.stats.goal) console.log(`  Statistik (Heim:Gast): Tore ${data.stats.goal.join(":")}, Schüsse ${data.stats.attempts?.join(":")}, Ecken ${data.stats.corner?.join(":")}, Ballbesitz ${data.stats.possession_percentage?.join(":")} %`);
  console.log(`  Video-Link: ${data.videoUrl ? "gefunden" : "FEHLT"}`);

  const summary = await backend.upsertRecording({
    veo_slug: recording.slug,
    title: data.title || recording.title,
    recorded_at: data.recordedAt || parseDate(recording.dateText),
    duration_seconds: data.durationSeconds ?? durationSeconds(recording.durationText),
    events: data.events,
    match_id: forcedMatchId ?? undefined,
    stats: data.stats,
    raw: { periods: JSON.stringify(data.periods), video_url: data.videoUrl ?? "", reel_url: data.reelUrl ?? "", orientation: data.orientationNote },
  });
  console.log(`  Status ${summary.status}${summary.review_notes?.length ? ` – ${summary.review_notes.join("; ")}` : ""}`);
  if (!withVideo) { console.log("  Ohne Video (Häkchen aus)"); return; }
  if (!summary.match_id) { console.log("  Kein Spiel zugeordnet – Video übersprungen"); return; }

  const cookies = await cookieHeader(veo.context);
  const work = path.join(config.paths.downloads, recording.slug);
  await fs.mkdir(work, { recursive: true });

  // 2) Veo's highlight clips first (small, fast): download → CDN.
  const clips = [];
  for (const [i, h] of data.highlights.entries()) {
    const name = `${h.type}-${Math.round(h.event_second)}`;
    try {
      const file = await downloadFile(h.video_url, path.join(work, `${name}.mp4`), { cookies, label: `Clip ${i + 1}/${data.highlights.length}` });
      const videoUrl = await upload(file, `matches/${summary.match_id}/clips/${name}.mp4`, "video/mp4");
      let thumbnailUrl = null;
      if (h.thumbnail_url) {
        const thumb = await downloadFile(h.thumbnail_url, path.join(work, `${name}.jpg`), { cookies, attempts: 3, label: "Vorschaubild" }).catch(() => null);
        if (thumb) thumbnailUrl = await upload(thumb, `matches/${summary.match_id}/clips/${name}.jpg`, "image/jpeg");
      }
      clips.push({ veo_event_id: h.veo_event_id, type: h.type, event_second: h.event_second, start_second: h.start_second,
                   end_second: h.end_second, video_url: videoUrl, thumbnail_url: thumbnailUrl });
    } catch (error) {
      console.log(`  ✗ Clip ${name} übersprungen: ${error.message}`);
    }
  }
  if (clips.length) await backend.addClips(recording.slug, clips);
  console.log(`  ${clips.length}/${data.highlights.length} Clips auf CDN`);

  // 3) Full match (large): direct link with retries + resume; Download button only as fallback.
  if (known?.has_video) { console.log("  Ganzes Spiel ist schon auf dem CDN"); return; }
  let videoFile;
  if (data.videoUrl) {
    videoFile = await downloadFile(data.videoUrl, path.join(work, "recording.mp4"), { cookies, label: "Ganzes Spiel" });
  } else {
    console.log("  Kein Direktlink – versuche Download-Button");
    videoFile = await downloadRecording(veo, recording.slug);
  }
  if (hasFfmpeg) videoFile = await faststart(videoFile).catch(() => videoFile);
  const url = await upload(videoFile, `matches/${summary.match_id}/recording.mp4`, "video/mp4");
  await backend.setVideo(recording.slug, url);
  console.log("  Ganzes Spiel auf CDN hochgeladen");
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
