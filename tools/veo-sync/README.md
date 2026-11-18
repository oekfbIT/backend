# Veo Sync (draft)

Imports Veo recordings into the ÖKFB backend: events (with jersey numbers), team stats, the full video and
highlight clips. The backend assigns each recording to an ÖKFB match and each event to a player (jersey number +
lineup, referee sheet wins for goals/cards). Unclear cases land in the admin review (`GET /admin/veo/recordings`).

## Setup

```bash
cd tools/veo-sync
npm install
npx playwright install chromium
brew install ffmpeg          # or apt-get install ffmpeg on the worker
```

Settings come from `BE/.env` (see `.env.example`): `VEO_EMAIL`, `VEO_PASSWORD`, `VEO_CLUB_URL`,
`VEO_SYNC_SERVICE_KEY`, `VEO_SYNC_BACKEND_URL`, `SPACES_*`.

## First run: discover Veo's data format

```bash
VEO_SYNC_HEADLESS=false npm run discover -- 20261115-bida-united-vs-as-vipers-v3b6395f
```

Opens the match in a visible browser, clicks through all tabs and saves every JSON response to
`captures/<slug>/`. Use these to replace the heuristics in `src/parse.mjs` (`findEvents`, `findStats`,
`normaliseTeams`) and to confirm the selectors marked `DRAFT` in `src/veo.mjs` (login, library, download dialog).

## Import

```bash
npm run sync -- --no-video                       # data only, all new recordings (max VEO_SYNC_MAX_PER_RUN)
npm run sync:one -- 20261115-bida-united-vs-as-vipers-v3b6395f   # one match incl. video + clips
```

## Backend endpoints (header `X-Veo-Sync-Key`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/veo-sync/known` | already imported slugs + status |
| POST | `/veo-sync/recordings` | recording + events + stats → match/player mapping |
| POST | `/veo-sync/recordings/:slug/video` | CDN URL of the full recording |
| POST | `/veo-sync/recordings/:slug/clips` | uploaded clips (replaces earlier ones) |

Public: `GET /webClient/match/:matchId/clips`, `GET /webClient/player/:playerId/clips`.
Admin: `GET /admin/veo/recordings?status=needsReview`, `POST /admin/veo/recordings/:slug/assign {"match_id"}`.
