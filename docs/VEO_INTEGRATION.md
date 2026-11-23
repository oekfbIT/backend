# Veo Integration

How ÖKFB imports match data and video from Veo, where it is stored, how the website shows it, and how the
mobile app can use it.

> Status (Nov 2026): data import, goal clips, stats and analytics work for single matches started from the admin.
> The worker runs on the developer Mac; production needs its own worker (see [Production](#production)).

---

## 1. Overview

```
 Admin (Spiel → Tab "Veo")                 Backend (Vapor)                      Veo (app.veo.co)
 ─────────────────────────                 ───────────────                      ────────────────
 [Spiel in Veo suchen & verbinden] ──POST──▶ starts worker process ──────────▶  headless Chrome, logged in
                                            (tools/veo-sync)                     reads the match page's own JSON
                                                │                                (events, clips, stats, analytics)
                                                ▼
                                   worker ──POST /veo-sync/*──▶ MongoDB: veo_recordings, match_clips
                                                │
                                                └── goal clips (mp4 + jpg) ──▶ DigitalOcean Spaces CDN
                                                                                matches/<matchId>/clips/

 Homepage / App  ──GET /webClient/...──▶ clips, stats, analytics, videos page
```

Veo has no public API. The worker logs in with a normal Veo account and reads the JSON that the Veo web app
itself loads (network responses), so no screen scraping of text is needed.

**Veo is only trusted for: times, positions, shirt numbers, event types and its own clip files.**
Teams and players always come from the ÖKFB match (line-ups + referee events).

---

## 2. Components

| Part | Where | What it does |
|---|---|---|
| Worker | `BE/tools/veo-sync/` (Node + Playwright) | Logs in to Veo, finds the recording, reads all panels, downloads goal clips, uploads to Spaces, sends data to the backend |
| Service API | `Sources/App/VeoSync/VeoSyncController.swift` | Endpoints for the worker (`/veo-sync/*`, secured by `X-Veo-Sync-Key`) |
| Matching | `Sources/App/VeoSync/VeoMatcher.swift` | Finds the ÖKFB match, decides teams from line-ups, maps players, links referee events |
| Models | `VeoModels.swift`, `VeoAnalytics.swift`, `VeoSyncJobs.swift` | `veo_recordings`, `match_clips`, `veo_sync_jobs` |
| Admin API | `Controllers/AdminController/AdminController+Veo.swift` | Start a sync for a match, status, review list, manual assignment |
| Public API | `Controllers/ClientController/ClientController+Clips.swift` | Clips, stats, analytics and the videos page for homepage and app |
| Admin UI | `oekfbFrontEndClient/.../matches/MatchVeoTab.jsx` | Tab "Veo" in the match detail |
| Website | `oekfb_hompage/src/components/MatchAnalysis/*`, `components/Videos/*`, `screens/ElementVideos` | Match tabs, Videos page, player/team clip rows |

---

## 3. Running an import (admin)

1. Admin → Ligen → Spiel → tab **Veo**.
2. Optional: paste the Veo link of the game (`https://app.veo.co/matches/<slug>/`) or just the slug.
   Empty = the worker searches the Veo library by team names and date.
3. Checkbox **Video herunterladen…** = also upload the clips to the CDN. Off = data only.
4. **Spiel in Veo suchen & verbinden**. The log updates every 3 s; a run takes ~2–5 min.

A run never hangs: page loads wait max. 60 s, downloads retry 6× with resume, the whole run stops after 60 min.
Re-running the same match updates the records (no duplicates).

Typical log:

```
Gewählt: Bida United vs. AS Vipers (20261115-bida-united-vs-as-vipers-v3b6395f)
106 JSON-Antworten, 8 Panels gelesen
Veo: 12 Tore, 37 Schüsse, 111 Ereignisse, 49 Veo-Clips
Statistik (Heim:Gast): Tore 8:4, Schüsse 24:13, Ecken 14:3, Ballbesitz 59:41 %
Status matched – ℹ︎ Teams über Kader/Ergebnis bestimmt (Passung 57 vs. -32)
Clips: 12 (goal) von 49
12/12 Clips auf CDN
```

### Settings (`BE/.env`)

| Variable | Default | Meaning |
|---|---|---|
| `VEO_EMAIL`, `VEO_PASSWORD` | – | Veo account (Editor role) |
| `VEO_CLUB_URL` | ÖKFB club library | Library page used to search recordings |
| `VEO_SYNC_SERVICE_KEY` | – | Shared secret worker ↔ backend |
| `VEO_SYNC_BACKEND_URL` | `http://localhost:8080` | Backend the worker talks to |
| `VEO_SYNC_HEADLESS` | `true` | `false` shows the browser (debugging) |
| `VEO_CLIP_TYPES` | `goal` | Which Veo clips go to the CDN: `goal,shot,penalty,save` |
| `VEO_SYNC_FULL_VIDEO` | `false` | Also download/upload the full match (several GB) |
| `VEO_SYNC_PRUNE_CDN` | `false` | Delete old clip files of the match in Spaces after a run |
| `SPACES_ENDPOINT`, `SPACES_REGION`, `SPACES_BUCKET`, `SPACES_KEY`, `SPACES_SECRET`, `SPACES_CDN_BASE` | – | DigitalOcean Spaces |

### Command line (optional)

```bash
cd BE/tools/veo-sync
node src/index.mjs match <matchId> --slug <veo-slug>       # what the admin button runs
node src/index.mjs match <matchId> --no-video               # data only
node src/index.mjs match <matchId> --types goal,shot        # override clip types for one run
node src/index.mjs discover <veo-slug>                      # only save Veo's raw data to captures/<slug>/
node src/index.mjs sync                                      # all library recordings not yet completed
```

Local folders (not in git): `captures/<slug>/` (raw JSON, `panels.json`, `analytics.json`, screenshots),
`downloads/<slug>/` (clip files), `.auth/veo-state.json` (saved Veo login – keep it).

---

## 4. What is read from Veo

| Veo panel | Source (JSON the page loads) | Stored as |
|---|---|---|
| Match info | `api/app/matches/<slug>/` | title, start time, duration |
| Halves | `…/periods/` | `analytics.periods[].start/end` (video seconds) |
| Videos | `…/videos/` | direct mp4 of the full match (only used with `VEO_SYNC_FULL_VIDEO`) |
| Events | `api/mes/v2/<id>/match-events` | `veo_recordings.events` (goals, shots, kick-offs, fouls, corners, free kicks, saves, cards) |
| Clips | `…/highlights/?include_ai=true` | `match_clips` (each Veo clip has its own mp4 + thumbnail) |
| Stats | `api/app/analysis/stats/` | `veo_recordings.stats` |
| Shot map | match events with `x`, `z` | `analytics.shots` |
| Pass / possession location | `…/match-details` | `analytics.periods[].pass_locations`, `possession_thirds`, … |
| Physical data | `…/physical-metrics` | `analytics.players` (distance, speed, sprints per shirt number) |
| Heat map | `…/player-tracking` | `analytics.heatmap` (optional; often not available) |

Passes, possession and duels are **not** stored as events (too many, too noisy).

---

## 5. Teams and players

Veo labels teams as "own" / "opponent" of the camera owner – for ÖKFB matches this is usually wrong.
The backend (`VeoMatcher.mapEvents`) decides:

1. **Orientation** – both ways (Veo side → home/away) get a score:
   +1 for every shirt number that exists only in that team's line-up, −1 if it exists only in the other one,
   +25 if the goal count then matches the real result. The better one wins.
2. **Per event** – if a shirt number exists only in the other team's line-up, the event moves to that team.
3. **Player** – line-up player with that shirt number (`homeBlanket` / `awayBlanket`).
4. **Referee wins** – goals and cards are paired in order with the referee's `MatchEvent`s of the same team;
   the referee's player replaces Veo's guess and `refereeEventId` is set.
5. Stats and analytics are flipped the same way (stored flag `sides_flipped`, so re-assigning is safe).

The reasoning is shown in the admin tab as `ℹ︎` notes. Notes without `ℹ︎` (e.g. a shirt number twice in a line-up)
set the status to `needsReview`.

Status values: `discovered`, `needsReview`, `matched`, `videoUploaded`, `completed`, `failed`.

---

## 6. Data model

### `veo_recordings` (one per Veo recording)

```jsonc
{
  "veo_slug": "20261115-bida-united-vs-as-vipers-v3b6395f",
  "title": "Bida United vs. AS Vipers",
  "recorded_at": "2026-11-15T14:58:30Z",
  "duration_seconds": 3243,
  "match": "<ÖKFB match id>",
  "status": "matched",
  "events": [ { "veo_id": "…", "type": "goal", "period": 1, "video_second": 108.2,
                "jersey_number": 10, "team": "home", "player_id": "…", "player_name": "…",
                "referee_event_id": "…" } ],
  "stats": { "goal": [8, 4], "goal_h1": [3, 3], "possession_percentage": [59, 41], … },   // [home, away]
  "analytics": { "shots": [...], "periods": [...], "heatmap": {...}, "players": [...] },
  "sides_flipped": false,
  "video_url": null,           // full match on the CDN, if VEO_SYNC_FULL_VIDEO
  "review_notes": ["ℹ︎ …"]
}
```

### `match_clips` (one per clip on the CDN)

```jsonc
{ "match": "<match id>", "source": "veo", "type": "goal",
  "event_second": 108.2, "start_second": 93, "end_second": 118,      // seconds in the Veo recording
  "team": "home", "player": "<player id>", "player_name": "…", "jersey_number": 9,
  "score_after": { "home": 1, "away": 0 },
  "video_url": "https://<cdn>/matches/<matchId>/clips/goal-108.mp4",
  "thumbnail_url": "https://<cdn>/matches/<matchId>/clips/goal-108.jpg" }
```

### `veo_sync_jobs` – one per admin run (status `running|completed|failed`, last 300 log lines).

---

## 7. API

All responses use snake_case (global JSON coder).

### Public (homepage, app) – `/webClient/…`

| Endpoint | Returns |
|---|---|
| `GET match/:matchId/videos` | `{ recording_url, clips[], stats, analytics }` – everything for one match |
| `GET match/:matchId/clips` | `clips[]` |
| `GET player/:playerId/clips` | `[{ clip, match }]` – clips of a player with match context |
| `GET team/:id/clips` | `[{ clip, match }]` – clips of all players of a team |
| `GET videos/league/:code` | `{ matches: [{ match, recording_url, thumbnail_url, clip_count }], clips: [{ clip, match }] }` |

`match` in these responses:
`{ id, gameday, date, home_name, away_name, home_logo, away_logo, home_team_id, away_team_id, score }`.

### Admin – `/admin/…` (admin auth)

| Endpoint | |
|---|---|
| `GET matches/:id/veo` | linked recording, latest job (with log), clip count |
| `POST matches/:id/veo/sync` | `{ "veo_url": "optional link or slug", "with_video": true }` – starts the worker |
| `GET veo/recordings?status=needsReview` | review list |
| `POST veo/recordings/:slug/assign` | `{ "match_id": "…" }` – assign manually |

### Worker – `/veo-sync/…` (header `X-Veo-Sync-Key`)

`GET known`, `GET match/:id`, `POST recordings`, `POST recordings/:slug/video`, `POST recordings/:slug/clips`.

---

## 8. On the website

### Match page (`/match/:id`)

A tab bar under the location (`SegmentedControl`). Tabs appear only when there is data:

| Tab | Shown when | Content |
|---|---|---|
| Statistik | `stats` | Veo-style rows with two bars; Gesamt / 1. / 2. Halbzeit |
| Aufstellung | always | the existing line-ups |
| Timeline | always (default) | the existing referee event list |
| Highlights | clips or recording | video player + goal list (minute, photo, scorer, score); clips play in a row |
| Schusskarte | `analytics` | pitch with all shots (goal = filled); card with player photo, name, minute |
| Pässe | `analytics` | pass positions per team and half, completed passes, own/opponent half split |
| Ballbesitz | `analytics` | possession % bar + minutes, thirds per team on the pitch |

Home is always black, away orange (same as the score boxes). One request: `useMatchVeo(id)` →
`GET match/:matchId/videos`.

### Videos page (`/videos`, menu "Videos")

Matches with video (cards → match page), **Alle Tore** grouped by matchday (rows like the Bundesliga site,
click = player overlay), **Highlights** (other clip types, if imported).

### Player and team pages

A clip row above the "Ewige Statistik" section (`ClipsSection`): the player's goals, or all goals of the team's
players. Hidden when there are no clips.

### Pitch drawing rules (also needed in the app)

- Veo positions: `x` 0…1 along the pitch **as filmed**, `y` 0…1 across. Values can be slightly outside 0…1 → clamp.
- Teams change ends at half-time. Per half, decide whether to mirror (`x → 1−x`, `y → 1−y`) so **home attacks
  right**: look at where each team's shots are (home shots should be at `x > 0.5`). See `mirrorByPeriod` in
  `components/MatchAnalysis/analysisUtils.ts`. Pass locations use the same frame.
- Match minute from a video second: `floor((second − period.start) / 60) + 1 + (half − 1) × 25`
  (`matchMinute`, 25-minute halves).
- `possession_thirds` are already from each team's own view (defensive / middle / attacking).

---

## 9. Using it in the app

Everything the app needs is in the public endpoints – no Veo access, no secrets.

### Match screen

```
GET /webClient/match/{matchId}/videos
```

```jsonc
{
  "recording_url": null,
  "clips": [ { "id": "…", "type": "goal", "event_second": 108.2, "team": "home",
               "player_id": "…", "player_name": "David Tal", "score_after": { "home": 1, "away": 0 },
               "video_url": "https://…/goal-108.mp4", "thumbnail_url": "https://…/goal-108.jpg" } ],
  "stats": { "goal": [8, 4], "possession_percentage": [59, 41], "goal_h1": [3, 3], … },
  "analytics": {
    "shots": [ { "veo_id": "…", "type": "shot", "team": "away", "period": 2, "video_second": 2575.3,
                 "x": 0.18, "y": 0.42, "jersey_number": 13 } ],
    "periods": [ { "period": 1, "start": 69, "end": 1602,
                   "possession_seconds": { "home": 395, "away": 214 },
                   "passes_completed": { "home": 87, "away": 52 },
                   "pass_locations": { "home": [[0.2, 0.34], …], "away": [...] },
                   "possession_thirds": { "home": { "attacking": 1794, "middle": 5284, "defensive": 4697 }, "away": {…} } } ],
    "players": [ { "jersey_number": 9, "team": "home", "distance": 2850, "max_speed": 24.1, "sprints": 3 } ]
  }
}
```

Suggested app UI (mirrors the website):

- **Segmented control** with the same tabs; hide tabs without data (`stats == null`, `analytics == null`, `clips` empty).
- **Highlights:** `AVPlayer` / ExoPlayer with `clips[i].video_url`; list below with `thumbnail_url`, minute
  (formula above), player from the match line-up by `player_id` (photo + name), `score_after`.
  The mp4s are on the CDN and stream directly; autoplay the next clip on end.
- **Statistik:** rows from `stats` – key → `[home, away]`, `_h1` / `_h2` suffix for halves.
  Labels: see `ROWS` in `components/MatchAnalysis/StatsPanel.tsx`.
- **Schusskarte / Pässe:** draw a pitch (Canvas/SwiftUI `Path`), apply the mirror rule per half, plot points.
  Player for a shot = line-up player with `team` + `jersey_number` (Veo's number – may be wrong; goals are reliable).
- **Ballbesitz:** `stats.possession_percentage` + `possession_thirds` per half.

### Player profile / team screen

```
GET /webClient/player/{playerId}/clips   → [{ clip, match }]
GET /webClient/team/{teamId}/clips       → [{ clip, match }]
```

Horizontal carousel of `clip.thumbnail_url`, tap → full-screen player with `clip.video_url`; subtitle from
`match` (`home_name score away_name · gameday. Spieltag`).

### Local phone preview

The Expo app's **Highlights** tab uses the match endpoint for video, statistics,
shots, passes and possession. Team and player highlights link back to the match
analysis.

Start the backend with the local connection from the `oekfbbackend` Xcode scheme
on port 8080. With the Mac and phone on the same Wi-Fi, start the preview server
from the backend repo. Replace `MAC_LAN_IP` with the Mac’s Wi-Fi IPv4 address.

```bash
VEO_PREVIEW_URL=http://MAC_LAN_IP:8083 node tools/veo-sync/src/local-preview.mjs \
  7EE832B2-147B-4EC7-809C-BF239C187CD3=20261115-bida-united-vs-as-vipers-v3b6395f \
  FF003371-0DFF-4440-A85E-F4864AADCF79=20261115-zuta-perla-vs-gruppe-gesundheit-va83dcc6
```

From the Expo app repo, start Metro against that preview address.

```bash
EXPO_PUBLIC_API_BASE_URL=http://MAC_LAN_IP:8083 npx expo start --lan --port 8082 --go
```

Scan the Expo QR code. Open **Bida United 8–4 AS Vipers**, **Bida United**, or
**David Tal** and select **Highlights**. The preview server reads the local
public API and serves existing media files from `tools/veo-sync/downloads`,
including byte ranges used by the phone’s video player. It leaves the database
and saved media URLs intact.

### Videos feed (e.g. a "Videos" tab in the app)

```
GET /webClient/videos/league/{leagueCode}
```

Group `clips` by `match.gameday` (newest first) for "Alle Tore"; `matches` for match cards.

### Ideas for later (data is already stored)

- Push notification / feed card when a match's goals are online (status → `matched` + clips).
- Running data per player (`analytics.players`: distance, top speed, sprints) on player profiles,
  matched by team + shirt number.
- Heat map per player (`analytics.heatmap.players`, 12×8 grid) when tracking data is available.
- Share button with the clip's CDN URL.

---

## 10. Production (DigitalOcean)

The worker does not run inside the API container (Chromium + downloads). It is its own **Worker** component in
the same App Platform app, built from `tools/veo-sync/Dockerfile`.

### How it works

```
Admin button ──POST /admin/matches/:id/veo/sync──▶ API (VEO_SYNC_MODE=queue)
                                                     └─ veo_sync_jobs { status: "queued" }
veo-worker (polls every 15 s) ──POST /veo-sync/jobs/claim──▶ API → job "running"
   └─ runs `node src/index.mjs match <matchId>` (child process)
   └─ every 3 s ──POST /veo-sync/jobs/:id/log──▶ API → admin tab shows the log
   └─ end: status completed | failed, local files deleted (VEO_SYNC_CLEANUP=true)
```

- `VEO_SYNC_MODE=local` (default, developer Mac): the API starts the worker itself, as before.
- `VEO_SYNC_MODE=queue` (production): the API only queues; the worker component runs the jobs.
- A queued job that no worker picks up within 30 min is marked failed ("Kein Worker…").
- On redeploy/stop the worker marks its running job failed so it can be started again.
- Optional `VEO_SYNC_NIGHTLY_HOUR=3`: every night at 03:00 (Vienna) all new library recordings are imported.

### Setup (once)

1. **API component** – App → *Settings* → API component → *Environment Variables*:
   - `VEO_SYNC_MODE` = `queue`
   - `VEO_SYNC_SERVICE_KEY` = long random string (Encrypt) – same value as in step 2
2. **Add the worker** – App → *Settings* → *App Spec* → *Edit*, paste the `workers:` block from
   [`.do/veo-worker.yaml`](../.do/veo-worker.yaml) and fill in the secrets (`VEO_EMAIL`, `VEO_PASSWORD`,
   `VEO_SYNC_SERVICE_KEY`, `SPACES_*` – same values as in `BE/.env`). Replace `api` in
   `${api.PRIVATE_URL}` with the name of your API component.
   *(Alternative in the UI: Create → Create Resources From Source Code → repo `oekfbIT/backend`, branch `main`,
   source directory `tools/veo-sync`, type **Worker**, Dockerfile `tools/veo-sync/Dockerfile`, size 1 GB RAM.)*
3. **Deploy.** The worker log (*Runtime Logs* → `veo-worker`) should show
   `Veo-Worker gestartet (Backend http://…, alle 15 s)`.
4. **Test:** admin → match → Veo → start. The log shows "In Warteschlange…", then "Worker hat den Auftrag
   übernommen", then the normal import log.

Size: 1 vCPU / 1 GB RAM, one instance (jobs run one after another). The disk is ephemeral; the worker deletes
clips and captures after each match. The Veo login is done once per container start.

### Local test with Docker

```bash
cd BE
docker compose --profile veo up --build app veo-worker   # app needs VEO_SYNC_MODE=queue in .env
# or only the worker against a running backend:
docker build -t veo-worker tools/veo-sync
docker run --rm --env-file .env -e VEO_SYNC_BACKEND_URL=http://host.docker.internal:8080 veo-worker
```

Worker env variables (in addition to section 3): `VEO_SYNC_POLL_SECONDS` (15), `VEO_SYNC_NIGHTLY_HOUR` (off),
`VEO_SYNC_CLEANUP` (`true` in the image).

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Missing VEO_* in BE/.env` | Add the variable; the worker reads `BE/.env` |
| Login fails | Wrong credentials or 2FA on the Veo account; delete `.auth/veo-state.json` and retry with `VEO_SYNC_HEADLESS=false` |
| `Veo-Bibliothek: 0 Aufnahmen` | Library page loaded slowly – paste the Veo link in the admin tab |
| `Keine passende Veo-Aufnahme gefunden` | Paste the Veo link |
| Teams wrong | Check the line-ups (shirt numbers) of the match, then re-run or use the assign endpoint |
| Status `needsReview` | Read the notes without `ℹ︎` in the admin tab |
| Clips missing on the website | Run with the video checkbox on; check `VEO_CLIP_TYPES` |
| `Tracking nicht erreichbar` | Heat map skipped – harmless |
| Job stays "running" | Server restarted during a run; after 30 min it is marked failed – start again |
