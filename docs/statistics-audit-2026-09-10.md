# Statistics audit — 2026-09-10

## Reproduced production discrepancy

Player: Manuel Huber, SID 17007, UUID `9C3DE3F6-F720-4800-8A80-1736C503924E`.

The public player endpoint returned 7 career appearances, 7 goals, 1 yellow card and 0 active-season appearances. An independent read of the 42 non-pending match sheets in his team's public three-season schedule found:

| Season | Recorded played appearances |
| --- | ---: |
| 2024/2025 | 14 |
| 2025/2026 | 13 |
| 2026/2027 | 1 |
| Total | 28 |

There is also one sheet containing him for an awarded, unplayed 6–0 forfeit. It belongs in the history but not in his appearances. The recorded personal events support 7 goals, 1 yellow card, no straight reds or yellow-reds, and a career goals-per-appearance average of 0.25. These are verified recorded figures, not a claim that the database contains his complete pre-2024 career.

The team's same 42 match records support 21 wins, 4 draws, 17 losses, 226 scored, 168 conceded, 67 result-derived points, 22 yellow cards and 1 straight red. The public website team statistics returned zero cards.

Read-only evidence sources:

- [Player API](https://api.oekfb.eu/webClient/player/detail/9C3DE3F6-F720-4800-8A80-1736C503924E)
- [Team schedule](https://api.oekfb.eu/webClient/clubs/detail/93675315-BC12-4DE5-814A-A9540C301287)
- [Missing 2024 appearance without an event](https://api.oekfb.eu/webClient/match/detail/3BFF885C-4C53-4344-8B24-CAA50A82EBDF)
- [Missing active-season appearance without an event](https://api.oekfb.eu/webClient/match/detail/1B19550C-FB10-4446-8AEB-B0696AEBE98E)

A minimized, checked-in fixture retains match/season/player IDs, scores, relevant sheet membership and card/personal-goal events. It excludes names, images, contact data and unrelated goals.

## Root causes and corrections

1. Fluent interprets the string-literal `FieldKey` "id" as its special root identifier. The Mongo driver translates it to `_id`. The old nested filter therefore queried `homeBlanket.players._id` / `awayBlanket.players._id`, but Codable stores those embedded keys as `id`. Both filters missed all sheet-only appearances, leaving only the seven event-bearing games. The shared paths now explicitly use `.string("id")`. A regression test invokes the actual installed Mongo driver's translation and verifies the BSON sheet key.
2. Website history and player statistics performed separate reads with separately cached results. Website and app player detail now derive totals and history from one shared snapshot, unioning both sheets with event-only participation and deduplicating match IDs.
3. Team calculators disagreed on statuses, forfeits, and card assignment; one compared player IDs against team IDs. A shared team calculator now uses explicit event assignment or original lineup membership. Direct reds and yellow-reds have separate totals.
4. Persistent 15-minute caches could retain wrong totals after event deletion, match updates, transfers or season activation. Statistics reads now use indexed source queries rather than those cached rows. Cache schemas and invalidation entry points remain for compatibility; existing cache documents are not rewritten or deleted by this review.
5. Database failures were converted into successful zeros or empty histories. They now propagate as request failures; the website displays an error instead of retaining another profile's data or presenting misleading figures.
6. Team history was restricted to the team's current league. Team history and the app team-fixtures route now include previous leagues. Missing season metadata is surfaced in a labelled history group rather than silently omitting a counted match.
7. Tables mixed career match statistics, current-season results and a mutable `team.points` accumulator. Public table endpoints now share season-scoped results, points, form and deterministic ranking.
8. Legacy leaderboards used the current roster instead of historical match membership. League and cross-league app leaderboards now share the match-scoped service, preserve transferred/deleted players' recorded events and exclude own goals from personal scoring.
9. App event presentation repeatedly fetched teams and computed statistics that the DTO did not contain. It now loads events' matches and players in batches without those discarded computations. Team rosters also use batch player calculations; app team responses expose additive `season_stats` alongside career `stats`.
10. Historical card removal used the player's current team and could fail after a transfer. It now corrects the recorded sheet. Goal creation records the actual score-receiving side consistently; removal can infer missing legacy assignment, including own goals.

## Rules and route coverage

- Player appearances: unique sheet/event-evidenced matches, excluding `pending` and `cancelled`; current-team membership alone never creates a historical appearance. Live matches count once they start.
- Player goals/cards and leaderboards: recorded events on countable matches. Own goals do not contribute to personal goal totals. Repeated references to the same event ID do not double-count.
- Team results: `completed`, `submitted`, `done`, `abbgebrochen`, and scored `cancelled` awards. Live/pending games and an unscored cancelled 0–0 do not become results. This preserves the backend's existing 6–0 no-show convention and historical abandoned-result policy.
- Active season: `Season.primary` in the current league; career totals are not current-league restricted. An empty primary season remains visible.
- Career/active player statistics: `/webClient/player/detail/:id`, `/app/player/:playerID`, `/app/player/sid/:sid`, app team rosters, legacy `/client/homepage/clubs/players/:playerID`, `/events/player/:playerId`, and model helpers.
- Team statistics/history: website club/team-section handlers, legacy client club handlers, app teams by ID/SID and team-fixture history, model helpers and app league summaries.
- Tables: website current and legacy table routes, legacy `/client/.../tabelle`, `/leagues/...` table handler, app league responses by ID/code and current table route. Explicit season admin W/D/L uses the same result policy.
- Leaderboards: website, legacy client/common league, app all-time and primary, plus cross-league primary top scorers.

## Performance and verification

- Existing registered `StatsQueryIndexesMigration` already creates the correct indexes on `homeBlanket.players.id`, `awayBlanket.players.id`, team/status, season, `match_events.playerId` and match/type. The corrected queries can use those indexes; no full-collection player-match scan is introduced.
- Player rosters, league team summaries and app event rendering use batch reads instead of per-player/per-event statistics queries. Primary-only team calculations restrict match reads to primary seasons. Duplicate player-detail history/statistics reads are removed.
- Tests cover the reported public-data fixture, actual Mongo field translation, both sides, event-only matches, duplicate IDs, own goals, missing/deleted associations, active/other leagues, all card categories, no-show awards, table/form consistency, historical editing and database errors.
- `swift test --skip-update`: 20 tests passed, including 10 statistics regressions. The website production build passed with output/cache in `/tmp`; it retains existing outdated-Browserslist warnings. Both repositories passed `git diff --check`.
- Live database execution plans and load-test latency were not measured. Fast indexed query structure is verified in code; production p95/p99 must be checked after deployment.

## Deployment and boundaries

No production database writes, migration execution, deployment, historical backfill or player identity merging were performed. Existing unrelated transfer/player-controller changes were preserved.

Deploy backend and website changes, confirm the registered indexes are present, then re-read the player and team APIs. Check 28/7/1 career appearances/goals/yellows and 1 active-season appearance against the then-current match data. Check website/app totals agree; history has 29 listed recorded sheets including the excluded forfeit. Monitor errors and query latency rather than treating timeouts as zeros.

Match-result-derived table points do not reconstruct manual disciplinary point adjustments: there is no explicit season-specific adjustment model in this repository. Raw administrative `team.points` fields remain stored and untouched. If manual deductions must appear in standings, they need an explicit, season-scoped adjustment source rather than inferring a deduction from an accumulated or stale total.

The review does not invent appearances for missing historical sheets, merge different player UUIDs by name/SID, or change disciplinary suspension rules. Existing multi-document goal/score writes are still not transactional across all mutation routes; reconciliation of pre-existing event-versus-score mismatches and transactional match editing are separate follow-up work. Team results intentionally use recorded match scores (including administrative awards), not the count of personal goal events.
