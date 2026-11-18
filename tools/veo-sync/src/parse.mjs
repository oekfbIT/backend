/**
 * Turns the JSON the Veo web app loaded into the backend's upsert shape.
 *
 * DRAFT: Veo's internal JSON format is not documented. Run `npm run discover -- <slug>` once: it saves every
 * captured response to captures/<slug>/. Then adapt `findEvents` / `findStats` to the real field names.
 * Until then the heuristics below look for arrays of objects that look like events.
 */

const TYPE_MAP = {
  goal: "goal", shot: "shot", "shot on goal": "shot", "shot_on_goal": "shot", corner: "corner",
  "free kick": "free_kick", free_kick: "free_kick", "goal kick": "goal_kick", goal_kick: "goal_kick",
  penalty: "penalty", "penalty kick": "penalty", kickoff: "kickoff", "kick off": "kickoff",
  "start period": "period_start", "period start": "period_start", "end period": "period_end", "period end": "period_end",
  "half-time": "period_end", tackle: "tackle", pass: "pass", "yellow card": "yellow_card", "red card": "red_card",
};

const normaliseType = (raw) => TYPE_MAP[String(raw || "").toLowerCase().replace(/[-_]+/g, " ").trim()]
  || TYPE_MAP[String(raw || "").toLowerCase()] || "other";

const toSeconds = (value) => {
  if (typeof value === "number") return value > 100000 ? value / 1000 : value; // ms → s
  if (typeof value === "string" && /^\d+(:\d+){1,2}$/.test(value)) return value.split(":").map(Number).reduce((a, b) => a * 60 + b, 0);
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
};

function* walk(node) {
  if (Array.isArray(node)) { yield node; for (const item of node) yield* walk(item); }
  else if (node && typeof node === "object") for (const value of Object.values(node)) yield* walk(value);
}

/** Heuristic: an array of objects with a type-like and a time-like field. */
export function findEvents(captured) {
  const events = [];
  const seen = new Set();
  for (const { body } of captured) {
    for (const array of walk(body)) {
      if (!array.length || typeof array[0] !== "object") continue;
      const sample = array[0];
      const typeKey = ["type", "event_type", "tag", "label", "name"].find((k) => k in sample);
      const timeKey = ["timestamp", "time", "start", "start_time", "offset", "video_time", "seconds"].find((k) => k in sample);
      if (!typeKey || !timeKey) continue;
      for (const item of array) {
        const second = toSeconds(item[timeKey]);
        if (second == null) continue;
        const id = String(item.id ?? item.uuid ?? `${item[typeKey]}-${second}`);
        if (seen.has(id)) continue;
        seen.add(id);
        const jersey = item.jersey_number ?? item.shirt_number ?? item.player?.jersey_number ?? item.player?.number;
        events.push({
          veo_id: id,
          type: normaliseType(item[typeKey]),
          veo_type: String(item[typeKey]),
          period: Number(item.period ?? item.half ?? 0) || null,
          video_second: second,
          veo_team: item.team_side ?? item.side ?? item.team ?? null,  // DRAFT: map own/opponent → home/away below
          jersey_number: jersey != null ? Number(jersey) : null,
          ai_detected: item.source ? /ai|auto/i.test(String(item.source)) : null,
        });
      }
    }
  }
  return events.sort((a, b) => a.video_second - b.video_second);
}

/** DRAFT: team stats from the Analytics tab → { goal: [home, away], shot: [...] }. */
export function findStats(captured) {
  for (const { body } of captured) {
    for (const array of walk(body)) {
      if (array.length && array[0] && typeof array[0] === "object" && "own" in array[0] && "opponent" in array[0]) {
        return Object.fromEntries(array.map((row) => [String(row.name ?? row.type ?? "stat").toLowerCase(), [Number(row.own), Number(row.opponent)]]));
      }
    }
  }
  return null;
}

/**
 * Veo labels teams "own" (the club's recording team) and "opponent". In the title "Home vs. Away" we don't know
 * which side "own" is, so the worker reports it as "home" by default and the backend corrects swapped titles.
 * DRAFT: replace once the real field is known.
 */
export function normaliseTeams(events) {
  return events.map((e) => {
    const raw = String(e.veo_team ?? "").toLowerCase();
    const team = /own|home|heim/.test(raw) ? "home" : /opp|away|gast/.test(raw) ? "away" : null;
    return { ...e, veo_team: team };
  });
}

/** "15 NOV 2026" → ISO date (noon UTC, the backend matches ±36 h). */
export function parseDate(text) {
  if (!text) return null;
  const months = { JAN: 0, FEB: 1, MAR: 2, APR: 3, MAY: 4, JUN: 5, JUL: 6, AUG: 7, SEP: 8, OCT: 9, NOV: 10, DEC: 11 };
  const m = text.toUpperCase().match(/(\d{1,2})\s+([A-Z]{3})\s+(\d{4})/);
  if (!m || !(m[2] in months)) return null;
  return new Date(Date.UTC(Number(m[3]), months[m[2]], Number(m[1]), 12)).toISOString();
}

export const durationSeconds = (text) => (text ? toSeconds(text) : null);
