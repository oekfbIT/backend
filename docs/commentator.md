# AI commentator: implementation and operations

## Scope and decisions

The commentator runs inside the existing Swift/Vapor deployment. There is no new
application, MCP server, Droplet, n8n installation, or automatic publication schedule.
An external scheduler or a later MCP adapter can invoke the same authenticated API.

The implementation plan was: inspect existing models/renderers; build cutoff-aware
shared facts; add a provider boundary; persist articles and durable jobs; add bounded
processing/authenticated routes; verify locally using mocked inference and disposable
MongoDB; prepare the feature branch for the owner to push without deployment.

Corrections identified before implementation:

- The specified `COMMENTATOR_CONTROLLER` did not exist. The new module is in
  `Sources/App/Commentator` and calls the existing statistics services directly.
- `Match.bericht` is a post-match report. It is never written by this module.
- News text is HTML: the homepage's `ElementNewsDetail` and `NewsArticle` components
  render rich content. Generated paragraphs are HTML-escaped and wrapped in `<p>`;
  the model cannot supply HTML. The reference article was inspected through its public
  news-detail JSON endpoint: it is titled `ÖKFB Spielbericht - 15.03.26` and contains
  approximately 25 KB of HTML. Its wording is not copied into generation prompts.
- `NewsItem.matchID` mistakenly used the `tag` storage key. It now uses `matchID`.
  Existing tags are preserved; no legacy values are guessed/backfilled.
- Current player eligibility/membership cannot reconstruct historical suspensions
  or rosters. Historical previews omit suspension claims.
- A JSON schema plus self-reported citations cannot prove arbitrary prose factual.
  This version deliberately uses **fact-constrained editorial selection**: the model
  selects/orders verified German sentences and title candidates; Vapor renders them.
  It is less linguistically flexible than unrestricted prose, but does not silently
  claim that heuristic name/number checks establish factual accuracy.

## Configuration

`.env` is ignored by Git. Fill the existing `OPENAI_API_KEY` placeholder locally and
configure the same variable as a secret in DigitalOcean App Platform. Never commit it.
No real inference is called by the tests.

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENAI_API_KEY` | empty | Direct OpenAI API credential; uses the API organization's balance |
| `COMMENTATOR_ENABLED` | `false` | Enables enqueueing and the in-process processor |
| `COMMENTATOR_AI_PROVIDER` | `openai` | `openai` or Responses-compatible `openai_compatible` adapter |
| `COMMENTATOR_AI_MODEL` | empty | Required model identifier; choose one supporting strict Structured Outputs |
| `COMMENTATOR_AI_BASE_URL` | `https://api.openai.com/v1` | HTTPS Responses API base URL |
| `COMMENTATOR_AI_API_KEY` | empty | Optional non-OpenAI/provider override; falls back to `OPENAI_API_KEY` |
| `COMMENTATOR_SERVICE_KEY` | empty | Dedicated service key, at least 32 bytes; empty disables service-key access |
| `COMMENTATOR_ALLOW_SERVICE_PUBLISH` | `false` | Explicitly grants publication/editing to the service credential |
| `COMMENTATOR_ALLOW_PARTIAL_PUBLISH` | `false` | Permits publication of clearly labelled incomplete-round summaries |
| `COMMENTATOR_CONCURRENCY` | `3` | Global generation slots across replicas; bounded to 1–5 |
| `COMMENTATOR_TIMEOUT_SECONDS` | `60` | Per-provider-call timeout; bounded to 5–120 |
| `COMMENTATOR_MAX_OUTPUT_TOKENS` | `1800` | Provider output budget, including any billed reasoning output |
| `COMMENTATOR_MAX_ATTEMPTS` | `3` | Maximum inference/job attempts, bounded to 1–5 |
| `COMMENTATOR_BATCH_LIMIT` | `150` | Maximum IDs in a batch, bounded to 1–200 |
| `COMMENTATOR_MAX_PREVIEW_WORDS` | `300` | Configurable safety ceiling, not a target length; normal previews remain short |
| `COMMENTATOR_MAX_SUMMARY_WORDS` | `900` | Round review upper word limit |
| `COMMENTATOR_POLL_SECONDS` | `5` | Pending-job polling interval |
| `COMMENTATOR_TEMPERATURE` | empty | Optional temperature; leave unset for models which do not support it |

Set `COMMENTATOR_ENABLED=true` only after configuring a model and key. Missing settings
produce a safe 503 on generation; normal football/news endpoints remain available.
The inference request uses `store:false` and strict JSON Schema. Contexts never include
emails, finances, identification documents, full Fluent models, or provider credentials.

The provider protocol is `AIInferenceService`; context, jobs, validation and storage do
not call an SDK. Another provider can implement it. Only the OpenAI/Responses-compatible
HTTP adapter is supplied here; a provider without that API requires another adapter.

## Authentication

All `/commenter/v1` endpoints accept either:

- An existing admin bearer session with `content.manage`, or
- `X-Commentator-Key: <dedicated service credential>` over HTTPS.

Service calls require no user login or refresh token. The key is compared through
fixed-length SHA-256 digests. Keep it in the caller's credential store; replace the
environment secret to rotate/revoke it. It is never part of model input or a URL.
The default service credential can read context and run explicit nonpublishing tests, but cannot publish or edit. For a trusted automation caller, set `COMMENTATOR_ALLOW_SERVICE_PUBLISH=true`; generation then publishes without a human approval step.
Existing user authentication remains unchanged. The generated OpenAPI lists both
authentication alternatives.

## API

Request DTOs accept the repository's normal JSON naming convention. Examples use
snake_case; the game-day request's `seasonId` also follows normal decoder conversion.
Job/article documents currently expose their stable identifier as `_id`.

| Method | Path | Behavior |
| --- | --- | --- |
| POST | `/commenter/v1/generate/match/:matchId` | Enqueue one preview; 202 with durable job |
| POST | `/commenter/v1/generate/matches/batch` | Bounded independent jobs, per-ID successes/errors; 202 |
| GET | `/commenter/v1/generate/match/:matchId/status` | Latest job plus current article |
| POST | `/commenter/v1/generate/gameday` | Enqueue a season/round review; 202 |
| GET | `/commenter/v1/generate/gameday/:seasonId/:number/status` | Latest job plus current round article |
| POST | `/commenter/v1/generate/gameday/:seasonId/:number/publish` | Publish an optionally withheld article to the existing news feed |
| POST | `/commenter/v1/generate/match/:matchId/publish` | Publish an optionally withheld preview |
| GET | `/commenter/v1/jobs/:jobId` | Exact job, attempts, safe error, result and snapshot |
| GET | `/commenter/v1/articles/:articleId` | Current article and metadata |
| PATCH | `/commenter/v1/articles/:articleId` | Editorial edit with `expected_revision`, `title`, `text`; published edits update the public copy directly |
| GET | `/commenter/v1/context/match/:matchId` | Traceable pre-match snapshot, no inference |
| GET | `/commenter/v1/context/gameday/:seasonId/:number` | Round snapshot; `?allowPartial=true` for incomplete rounds |
| GET | `/webClient/match/:matchId/preview` | Public published preview only; otherwise 404 |
| GET | `/webClient/match/:matchId/form` | Home/away recent form in this season, before the fixture cutoff |

Match options (all optional):

```json
{"language":"de","publish":true,"overwrite":false,"dry_run":false,"idempotency_key":"preview-pass-1"}
```

Batch body:

```json
{"match_ids":["MATCH_UUID"],"options":{"language":"de","publish":true,"idempotency_key":"batch-pass-1"}}
```

Round body:

```json
{"season_id":"SEASON_UUID","gameday":12,"language":"de","publish":true,"overwrite":false,"allow_partial":false}
```

**Publication is the default**, including when the body/options or `publish` field is
omitted. Normal processing is context → AI selection → factual validation → persistence
→ publication → completed job. No admin session, confirmation or later publish request
is needed for an authorized service caller. Match previews become public and game-day
reviews create/update their single existing news record. Jobs only report completed
after requested publication succeeds. This supersedes the original attached document's
draft-by-default workflow.

Use `publish:false` only to deliberately withhold a test/review article. The internal
`draft` value is retained for these opt-out articles and backward compatibility; it is
not a required editorial stage. `dry_run:true` defaults to nonpublishing and stores only
the job result. Explicit `dry_run:true,publish:true` remains invalid.

`Idempotency-Key` can also supply the key. With no key, `initial` is used per target,
language and dry-run/persist mode. Repeating an initial request returns the original
job rather than spending again. To intentionally regenerate, supply `overwrite:true`
and a **new** explicit idempotency key. Reuse a key when retrying the same request.
A key cannot be reused to change publication or overwrite intent. Language is limited
to `de`/`de-AT` and stored canonically as `de`.

Existing pre-change jobs keep their recorded publication intent. Reusing an old test
key with automatic publication now returns 409 rather than silently returning an
unpublished result; publish that saved article directly or use a new key with explicit
overwrite to regenerate. Existing saved articles require no migration or automatic
backfill/publication.

`dry_run:true` still performs paid inference and stores a job/result for inspection;
it does not save an article or create news. Use the context GETs for a no-inference
inspection. Dry runs cannot publish. Batch duplicates are deduplicated; errors for one
target do not roll back other jobs. Batch context preparation reuses season reads.

## Chronology and factual guarantees

- Preview cutoff is `min(kickoff, snapshot creation time)`. The target match and later
  results are excluded, including from head-to-head and player contributions.
- A result needs a known kickoff, an accepted terminal status and a recorded end time
  no later than cutoff. Without an end time, a conservative six-hour gap is required.
  Abandoned and undated fixtures are not asserted as completed results.
- Historical previews are labelled retrospective and do not claim current suspensions.
- Future fixture suspensions require `eligibility=Gesperrt` and `blockdate > kickoff`.
  The backend treats blockdate as release time, so equality is not an absence. A missing
  expiry or a ban ending before kickoff is insufficient. Historical previews still omit
  current suspension claims. Confirmed absences are mandatory facts for both teams.
- Absence importance uses the last five reliably completed team matches: recorded goals,
  match-report roster entries and actual player events. A roster entry is described as
  a match-report listing, never as minutes played or a starting appearance. Recent games
  never override a current ban. Confirmed absentees and known transferred players are
  excluded from attacking players-to-watch facts. No injuries or lineups are invented.
- Scorers use historical match/event assignments; own goals and awarded results do not
  increase personal scorer totals. Unknown player identities are not merged by name.
- Awarded 6–0 results remain distinguishable from goals scored on the pitch.
- Round tables use recorded results through the requested round number and cutoff,
  including earlier rounds. They do not silently include later rounds.
- Incomplete rounds fail with 409 unless `allow_partial:true`; partial status is a
  mandatory sentence/title attribute. Publication remains independently restricted.
- The source snapshot, selected fact IDs, context hash, model, prompt version, provider
  and token usage are stored. Edited articles are marked manual and lose automatic
  fact-selection attribution.

The provider schema enumerates the allowed title/fact IDs. The backend inserts mandatory
framing, deduplicates references, ensures both teams have coverage, and measures the word
budget using complete verified sentences. It can trim/add facts from the same snapshot;
it cannot repair an unknown fact by inventing text. Unsupported IDs still fail validation.

This cannot reconstruct when old results were entered/corrected or historical roster
and suspension changes which were never recorded. Source-data accuracy and league
tie-break rules remain those of the backend. The model cannot introduce new claims,
but the quality of the article still depends on those recorded facts and calculations.

## Concise match previews and player angles

`matchup-brief-de-v4` usually targets about 80–140 words for routine previews, with
no 150-word editorial ceiling. Important absences, scorer milestones and other meaningful
stories may justify a longer article, up to the configurable safety ceiling (default
300 words). Extra words must add relevant information; no padding to reach a word count.
The validation floor is only 25 words, adapting down further to genuinely sparse context. Compact records
use wins–draws–losses, labelled `S–U–N`. Selection avoids duplicate form/streak claims,
multiple table comparisons and repeated scorer facts. Header date/venue are omitted from
normal prose when team stories are available, while remaining in the context. Statistics provenance belongs in
stored context/metadata, rather than repeated boilerplate in every sentence.

Attack/defence angles use the last five results (at least three matches and at least
three goals scored/conceded per played match on average for those particular descriptions).
Awarded results count in the record, explicitly labelled, but their administrative goals
are excluded from played-goal totals and attack/defence descriptions.
The model chooses contrasting form, splits, player contributions, confirmed absences
or one recent meeting, rather than listing everything. The fact-based selection
architecture remains: this is curated football prose, not unrestricted invented copy.

A league scorer snapshot is built once per fixture from already-loaded season events.
Milestones are emitted only when unique goal events reconcile with BOTH sides of EVERY
completed, played match's score at the cutoff and non-own-goal scorers can be identified.
Own goals do not increase a player's tally. Unplayed awarded results do not add scorers.
Missing or ambiguous goals suppress league ranking claims rather than guessing a top 10.
Ties use shared competition ranks. Top-10 hypotheticals explicitly hold the rest of the
current standings unchanged; close leader gaps name the leader and goal total. These
are arithmetic milestones, not a claim that a player will score or a confirmed lineup.

Card context covers the last five team matches, deduplicates event IDs, distinguishes
red from yellow-red, and highlights recorded dismissals or at least three yellows.
No future card, foul count or automatic ban is inferred. Free kicks and penalties are
not foul statistics. A real absence is based on the player registry's ban end time.
The extra calculations reuse loaded matches/events and add no per-player database calls.

## Persistence, retries and publication

New Mongo collections: `commentary_jobs`, `commentary_articles`, `commentary_leases`.
The additive `CommentaryIndexesMigration` adds pending-job, target-history, and
season/game-day query indexes. Deterministic Mongo `_id` values provide uniqueness.
No existing match document needs a preview field or backfill. `bericht` is untouched.

The existing Vapor process polls jobs, acquires one of the globally bounded generation
slots, claims a job atomically and renews its lease. Deployments/restarts can reclaim
expired work. Maximum attempts and capped backoff cover transport errors, timeouts,
429, 408 and 5xx. Invalid output, refusals and permanent errors fail without endless
retry. Provider response bodies/secrets are not stored as errors.

Article revisions use compare-and-set. An edit after enqueue prevents stale output
from replacing it. Regeneration never edits an existing published news story unless
publication is also requested. A saved article can recover the article-save/job-finish
crash window without another inference call. An unavoidable crash after provider
completion but before durable storage can result in one additional paid attempt.

News publication uses the existing `news` collection, its league code tag and a stable
news UUID per season/round/language. A retry cannot insert another story. Published news
which changed outside this workflow requires explicit overwrite. No image URL or push
notification is generated. Revisions are recorded through job results/context; the
article collection stores the current editorial revision, not a full manual-edit log.

No scheduled publication is configured. A future scheduler can POST the same generation
endpoints with a stable run key. Generation is always asynchronous; the HTTP request
does not wait for AI completion.

## Manual admin and homepage workflow

The admin match-detail screen has a **KI-Spielvorschau** tab for manual triggers,
testing and review; it never triggers generation merely by opening the screen.
**Spielvorschau erstellen** shows durable progress and automatically publishes the
validated result. No separate approval is required. **Nur testen (nicht veröffentlichen)**
is an explicit opt-out for testing, and preserves any existing public version.

A readable **Textansicht** updates while editing the title/body. **Speichern und
veröffentlichen** writes edits directly to the public preview. Only deliberately
unpublished test articles offer a separate publish button. Regeneration uses a new
idempotency key, and requires confirmation before replacing existing content.
The programmatic endpoints do not require that UI confirmation.

`PATCH /commenter/v1/articles/:articleId` accepts optional `publish`. When omitted,
editing published content keeps it published, including game-day news; unpublished
articles remain unpublished. `publish:true` saves/publishes in one call, while
`publish:false` deliberately withholds the edit. Expected revisions prevent stale edits
from overwriting newer changes. News edits through the existing news editor are also
preserved unless an explicit overwrite is requested; use the commentator article PATCH
for changes that should remain synchronized with generation metadata.

The homepage fetches the published preview and home/away form independently of its
match-detail request. It displays five result slots underneath each team identity,
oldest on the left and newest on the right, with a link/tooltip for each known result.
The preview paragraphs are centered beneath the match status. Missing previews remain
absent, and unavailable form is distinguished from genuinely missing historical results.

For an isolated local run, start MongoDB on a loopback port, load test/public fixtures
into `oekfb_commentator_local`, build the API, then run:

```sh
python3 tools/run_commentator_local.py --model gpt-4.1-mini
```

The helper reads the ignored `.env` for model credentials, forces MongoDB to
`127.0.0.1:27029/oekfb_commentator_local`, binds the API to `127.0.0.1:8080`, and disables
unrelated analytics imports. It never uses the production connection string. Override
the local ports with `--mongo-port` / `--port`. The model is an explicit operator choice,
not a hardcoded production default. No automatic generation/publication schedule is added.

The existing frontend development servers default to the local API:
admin `http://localhost:3000`, homepage `http://localhost:1234`.

## Local verification

Run the existing test suite with a disposable, loopback-only MongoDB port:

```sh
COMMENTATOR_TEST_MONGO_PORT=YOUR_LOCAL_PORT swift test --jobs 4
```

Tests use unique disposable database names and never call `configure(app)` or live AI.
They cover cutoffs, missing statistics, fixture eligibility, output validation, safe
HTML, provider errors/timeouts, permissions, HTTP enqueue/status, retries, idempotency,
Mongo writes, expired leases, manual-edit protection, dry runs, news publication and
preservation of post-match reports. Without the explicit local port, database tests skip.

The checked-in `.env.example` contains empty credentials. Local `.env` must remain ignored.
Push/deployment are separate: pushing this branch does not authorize changes to production.

Verified locally on 2026-11-09: final backend run reported 130 tests, zero failures
and 33 pre-existing opt-in skips. All 21 commentator tests passed, including isolated
MongoDB integration tests. The admin's four workflow/regression tests and nine homepage
tests passed, and both frontend production builds succeeded.

Automated tests use mocked inference. A separate live local browser check used the
configured OpenAI key, found and corrected reference/word-budget consistency failures,
then verified generation, editing, local publication and homepage display.
Only the isolated local database was written. No production data or scheduler was changed.

Automatic-publication follow-up verification: 134 backend tests, zero failures, 33
pre-existing opt-in skips; all 25 commentator tests passed. This includes programmatic
game-day generation/publication, duplicate prevention, default-publication permissions,
partial-round rejection, preview crash recovery, and direct edits to published previews
and news. Six admin workflow/regression tests and the admin production build passed.

Editorial follow-up: 140 backend tests, zero failures, 33 existing opt-in skips; all
31 commentator tests passed. New cases cover complete/incomplete scorer data, shared
top-10 qualification, named leader gaps, own goals, cutoff-safe card history, concise
selection, suspension expiry boundaries, recent involvement without invented starts, and exclusion
of awarded goals from played attack/defence totals. A live local test on FC Playboys–FC
Bacishta used the existing public squad/suspension feed to verify Semir Bedžeti’s recorded
ban covers kickoff. No production records were changed.

Flexible-length regression: the focused commentator suite covers allowing a supported
preview above 150 words while preserving a shorter selection without padding.
