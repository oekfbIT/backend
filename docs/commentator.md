# AI commentator: implementation and operations

## Scope and decisions

The commentator runs inside the existing Swift/Vapor deployment. There is no new
application, MCP server, Droplet, n8n installation, or automatic publication schedule.
An external scheduler or a later MCP adapter can invoke the same authenticated API.

The implementation plan was: inspect existing models/renderers; build cutoff-aware
shared facts; add a provider boundary; persist drafts and durable jobs; add bounded
processing/authenticated routes; verify locally using mocked inference and disposable
MongoDB; push the feature branch without deployment.

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
| `COMMENTATOR_ALLOW_PARTIAL_PUBLISH` | `false` | Permits publication of clearly labelled incomplete-round drafts |
| `COMMENTATOR_CONCURRENCY` | `3` | Global generation slots across replicas; bounded to 1–5 |
| `COMMENTATOR_TIMEOUT_SECONDS` | `60` | Per-provider-call timeout; bounded to 5–120 |
| `COMMENTATOR_MAX_OUTPUT_TOKENS` | `1800` | Provider output budget, including any billed reasoning output |
| `COMMENTATOR_MAX_ATTEMPTS` | `3` | Maximum inference/job attempts, bounded to 1–5 |
| `COMMENTATOR_BATCH_LIMIT` | `150` | Maximum IDs in a batch, bounded to 1–200 |
| `COMMENTATOR_MAX_PREVIEW_WORDS` | `250` | Preview upper word limit |
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
The default service credential can create/read drafts but cannot publish or edit.
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
| POST | `/commenter/v1/generate/gameday/:seasonId/:number/publish` | Explicitly publish draft to existing news feed |
| POST | `/commenter/v1/generate/match/:matchId/publish` | Explicitly publish preview |
| GET | `/commenter/v1/jobs/:jobId` | Exact job, attempts, safe error, result and snapshot |
| GET | `/commenter/v1/articles/:articleId` | Current draft/published article and metadata |
| PATCH | `/commenter/v1/articles/:articleId` | Explicit editorial edit with `expected_revision`, `title`, `text` |
| GET | `/commenter/v1/context/match/:matchId` | Traceable pre-match snapshot, no inference |
| GET | `/commenter/v1/context/gameday/:seasonId/:number` | Round snapshot; `?allowPartial=true` for incomplete rounds |
| GET | `/webClient/match/:matchId/preview` | Public, explicitly published preview only; otherwise 404 |

Match options (all optional):

```json
{"language":"de","publish":false,"overwrite":false,"dry_run":false,"idempotency_key":"preview-pass-1"}
```

Batch body:

```json
{"match_ids":["MATCH_UUID"],"options":{"language":"de","publish":false,"idempotency_key":"batch-pass-1"}}
```

Round body:

```json
{"season_id":"SEASON_UUID","gameday":12,"language":"de","publish":false,"overwrite":false,"allow_partial":false}
```

`Idempotency-Key` can also supply the key. With no key, `initial` is used per target,
language and dry-run/persist mode. Repeating an initial request returns the original
job rather than spending again. To intentionally regenerate, supply `overwrite:true`
and a **new** explicit idempotency key. Reuse a key when retrying the same request.
A key cannot be reused to change publication or overwrite intent. Language is limited
to `de`/`de-AT` and stored canonically as `de`.

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
- Future fixture suspensions require a recorded blocked state and block-end time that
  encompasses kickoff. No injuries or confirmed lineups are invented.
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

This cannot reconstruct when old results were entered/corrected or historical roster
and suspension changes which were never recorded. Source-data accuracy and league
tie-break rules remain those of the backend. The model cannot introduce new claims,
but the quality of the article still depends on those recorded facts and calculations.

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

Verified locally on 2026-11-09: build succeeded; one full test run reported 126 tests,
zero failures and 33 pre-existing opt-in skips. All 17 commentator tests passed,
including isolated MongoDB integration tests. No paid inference was performed.
