import { veoGet } from "./veo.mjs";
/**
 * Veo "Analytics" panel → one object stored with the recording (all sides oriented to home/away):
 *   shots       shot map: every shot/goal with pitch position (x 0..1 along the pitch as filmed, y 0..1 across)
 *   periods[]   per half: possession seconds, passes, possession won, pass locations + 18-zone grid,
 *               possession thirds + 18-zone grid, pass strings
 *   heatmap     12×8 grid of tracked positions per team and per player (jersey), per half
 *   players     physical metrics per jersey (distance, speed, sprints, high-speed running)
 *
 * Veo reports left/right of the camera. The own team's side per half comes from /periods/ (own_side),
 * and own/opponent → home/away from parseVeo (checked against the real score).
 */
const find = (captured, re) => captured.find((c) => re.test(c.url) && c.status < 300)?.body;
const GRID_X = 12, GRID_Y = 8;

export function buildAnalytics(captured, data, tracking) {
  const periodsRaw = find(captured, /\/periods\/$/) || [];
  const details = find(captured, /\/match-details/) || [];
  // Side (L/R) → home/away for each half.
  const sideOf = (periodIndex, lr) => {
    const own = (periodsRaw[periodIndex]?.own_side || "left").startsWith("l") ? "L" : "R";
    return lr === own ? data.sides.Own : data.sides.Opponent;
  };
  const pair = (period, obj, pick = (v) => v) => {
    const out = { home: null, away: null };
    for (const lr of ["L", "R"]) if (obj && lr in obj) out[sideOf(period, lr)] = pick(obj[lr]);
    return out;
  };

  const periods = details.map((p, i) => ({
    period: i + 1, start: p.start, end: p.end,
    possessionSeconds: pair(i, p.stats?.PossessionSeconds, (v) => Math.round(v)),
    passesCompleted: pair(i, p.stats?.PassesCompleted),
    possessionWon: pair(i, p.stats?.PossessionWon),
    passLocations: pair(i, p.passLocations, (list) => list.map((pt) => [pt.x, pt.y])),
    passGrid: pair(i, p.passLocationsGrid, (g) => g.values),
    possessionThirds: pair(i, p.possessionLocations),
    possessionGrid: pair(i, p.possessionLocationsGrid, (g) => g.values),
    passStrings: pair(i, p.passStrings),
  }));

  const rawEvents = find(captured, /\/match-events/)?.events || [];
  const shots = rawEvents.filter((e) => e.eventType === "FootballShot" || e.eventType === "FootballGoal").map((e) => ({
    veoId: e.id, type: e.eventType === "FootballGoal" ? "goal" : "shot", team: data.sides[e.team] ?? null,
    period: e.periodId, videoSecond: e.videoTimeMs / 1000, x: e.x, y: e.z,
    jerseyNumber: /^\d+$/.test(e.playerJersey ?? "") ? Number(e.playerJersey) : null, outcome: e.outcome,
  }));

  // Physical metrics: drill "ALL" = whole match per jersey.
  const physical = find(captured, /\/physical-metrics/) || [];
  const players = physical.filter((p) => p.drill === "ALL" && p.jerseyNumber != null).map((p) => ({
    jerseyNumber: p.jerseyNumber, team: p.teamId ? data.sides.Own : data.sides.Opponent,
    distance: p.distance, secondsPlayed: p.secondsPlayed, maxSpeed: p.maxSpeed, averageSpeed: p.averageSpeed,
    sprints: p.sprints, hsr: p.hsr,
  }));

  // Heat map from tracking frames: [trackId, class, x, y, jersey, ?, speed, side(1=L,2=R)].
  const heatmap = { gridX: GRID_X, gridY: GRID_Y, teams: [], players: [] };
  const teamGrids = new Map(), playerGrids = new Map();
  const cell = (x, y) => Math.min(GRID_X - 1, Math.max(0, Math.floor(x * GRID_X))) + GRID_X * Math.min(GRID_Y - 1, Math.max(0, Math.floor(y * GRID_Y)));
  for (const [t, objects] of Object.entries(tracking || {})) {
    const time = Number(t);
    const pIndex = periodsRaw.findIndex((p) => time >= p.timeframe[0] && time <= p.timeframe[1]);
    if (pIndex < 0) continue;
    for (const o of objects) {
      const [, , x, y, jersey, , , side] = o;
      if (side !== 1 && side !== 2) continue; // ball, referee, unknown
      const team = sideOf(pIndex, side === 1 ? "L" : "R");
      const tk = `${team}|${pIndex + 1}`;
      if (!teamGrids.has(tk)) teamGrids.set(tk, new Array(GRID_X * GRID_Y).fill(0));
      teamGrids.get(tk)[cell(x, y)]++;
      if (jersey > 0) {
        const pk = `${team}|${jersey}`;
        if (!playerGrids.has(pk)) playerGrids.set(pk, new Array(GRID_X * GRID_Y).fill(0));
        playerGrids.get(pk)[cell(x, y)]++;
      }
    }
  }
  for (const [k, values] of teamGrids) { const [team, period] = k.split("|"); heatmap.teams.push({ team, period: Number(period), values }); }
  for (const [k, values] of playerGrids) { const [team, jersey] = k.split("|"); heatmap.players.push({ team, jerseyNumber: Number(jersey), values }); }

  return { shots, periods, heatmap, players, trackingFrames: Object.keys(tracking || {}).length };
}

/** Loads the whole player tracking (the page only loads ~100 s around the playhead). 24 s per request. */
export async function fetchTracking(veo, matchId, periods, captured) {
  const frames = {};
  for (const c of captured) if (/\/player-tracking\?start=/.test(c.url) && c.body && typeof c.body === "object") Object.assign(frames, c.body);
  const starts = [];
  for (const p of periods) for (let s = p.start; s < p.end; s += 24) starts.push(Math.round(s));
  let ok = 0, failed = 0;
  for (let i = 0; i < starts.length; i += 4) {
    if (failed >= 8 && ok === 0) { console.log("  Tracking nicht erreichbar – Heatmap nur aus geladenen Daten"); break; }
    await Promise.all(starts.slice(i, i + 4).map(async (start) => {
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const r = await veoGet(veo, `https://app.veo.co/api/mes/v2/${matchId}/player-tracking?start=${start}`, 1);
          if (!r?.body) throw new Error(`HTTP ${r?.status}`);
          Object.assign(frames, r.body); ok++; return;
        } catch { await new Promise((res) => setTimeout(res, 1500 * attempt)); }
      }
      failed++;
    }));
  }
  console.log(`  Tracking: ${ok}/${starts.length} Abschnitte geladen${failed ? `, ${failed} fehlgeschlagen` : ""}`);
  return frames;
}
