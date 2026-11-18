/**
 * Exact parser for the JSON the Veo web app loads (written against real captures, Nov 2026):
 *   api/app/matches/<slug>/               match: title, start, duration, own_team_home_or_away
 *   api/app/matches/<slug>/periods/       halves: timeframe [startSec, endSec]
 *   api/app/matches/<slug>/videos/        renders: standard (1080p follow-cam) = the file we store
 *   api/mes/v2/<id>/match-events          all events: eventType, team Own|Opponent, videoTimeMs, playerJersey, assist
 *   api/app/matches/<slug>/highlights/    Veo's clips (goal, shot_on_goal) with their own mp4 + thumbnail
 */

const find = (captured, re) => captured.find((c) => re.test(c.url) && c.status < 300)?.body;

// Veo eventType → our type. Everything else (pass, possession, duel…) is dropped: too noisy for the site.
const EVENT_TYPES = {
  FootballGoal: "goal", FootballShot: "shot", FootballKickOff: "kickoff", FootballFoul: "foul",
  FootballCornerKick: "corner", FootballFreeKick: "free_kick", FootballPenalty: "penalty", FootballPenaltyKick: "penalty",
  FootballYellowCard: "yellow_card", FootballRedCard: "red_card", save: "save",
};
const HIGHLIGHT_TYPES = { goal: "goal", shot_on_goal: "shot", penalty: "penalty", save: "save" };

/**
 * @param captured  responses from captureMatch
 * @param score     optional real result { home, away } – used to decide which Veo side is home
 */
export function parseVeo(captured, score) {
  const match = find(captured, /\/api\/app\/matches\/[^/]+\/$/);
  const periods = (find(captured, /\/periods\/$/) || []).map((p, i) => ({ period: i + 1, start: p.timeframe?.[0], end: p.timeframe?.[1] }));
  const videos = find(captured, /\/videos\/$/) || [];
  const standard = videos.find((v) => v.render_type === "standard" && v.availability === "available") || videos.find((v) => v.mime_type === "video/mp4");
  const rawEvents = find(captured, /\/match-events/)?.events || [];
  const rawHighlights = find(captured, /\/highlights\//) || [];

  // Own/Opponent → home/away. Veo's own side comes from the camera owner and is often wrong for us,
  // so if the real score is known, pick the orientation whose goal count matches it.
  const ownIsHome = (match?.own_team_home_or_away || "home") === "home";
  let mapping = { Own: ownIsHome ? "home" : "away", Opponent: ownIsHome ? "away" : "home" };
  const goals = rawEvents.filter((e) => e.eventType === "FootballGoal");
  let orientationNote = "Seiten laut Veo (own = " + (ownIsHome ? "home" : "away") + ")";
  if (score && goals.length) {
    const count = (side) => goals.filter((g) => mapping[g.team] === side).length;
    const direct = count("home") === score.home && count("away") === score.away;
    const swapped = count("away") === score.home && count("home") === score.away;
    if (!direct && swapped) { mapping = { Own: mapping.Opponent, Opponent: mapping.Own }; orientationNote = "Seiten getauscht (Tore passen zum Ergebnis)"; }
    else if (direct) orientationNote = "Seiten passen zum Ergebnis";
    else orientationNote = `Tore laut Veo ${count("home")}:${count("away")}, Ergebnis ${score.home}:${score.away} – Seiten bitte prüfen`;
  }

  const events = rawEvents
    .filter((e) => EVENT_TYPES[e.eventType])
    .map((e) => ({
      veo_id: e.id,
      type: EVENT_TYPES[e.eventType],
      veo_type: e.eventType,
      period: e.periodId ?? null,
      video_second: e.videoTimeMs / 1000,
      veo_team: mapping[e.team] ?? null,
      jersey_number: /^\d+$/.test(e.playerJersey ?? "") ? Number(e.playerJersey) : null,
      ai_detected: true,
    }))
    .sort((a, b) => a.video_second - b.video_second);

  // Veo highlights: own video files. Link each to the event it shows (same type, inside its time window).
  const highlights = rawHighlights
    .filter((h) => HIGHLIGHT_TYPES[h.type] && h.videos?.[0]?.url)
    .map((h) => {
      const type = HIGHLIGHT_TYPES[h.type];
      const start = h.start, end = h.start + (h.duration || 25);
      const candidates = events.filter((e) => e.type === type && e.video_second >= start - 2 && e.video_second <= end + 2);
      const mid = start + (end - start) * 0.6;
      const event = candidates.sort((a, b) => Math.abs(a.video_second - mid) - Math.abs(b.video_second - mid))[0];
      return {
        veo_highlight_id: h.id, type, start_second: start, end_second: end,
        event_second: event?.video_second ?? mid, veo_event_id: event?.veo_id ?? null,
        video_url: h.videos[0].url, thumbnail_url: h.thumbnail || null,
      };
    })
    .sort((a, b) => a.start_second - b.start_second);

  return {
    title: match?.title, recordedAt: match?.start ?? null, durationSeconds: match?.duration ?? null,
    periods, videoUrl: standard?.url ?? null, reelUrl: match?.reel_url ?? null,
    events, highlights, orientationNote,
  };
}
