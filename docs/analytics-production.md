# Native GA4 importer: DigitalOcean App Platform

The importer now runs **inside the existing Swift/Vapor backend**. No Python runtime, extra DigitalOcean component, cron job, uploaded credential file, or custom startup command is needed.

## Set production variables

DigitalOcean → Apps → **backend-api** → Settings → select the backend service component → Environment Variables → Edit.

| Key | Value | Scope | Encrypt |
| --- | --- | --- | --- |
| `GA4_ENABLED` | `true` | Run time | No |
| `GA4_SERVICE_ACCOUNT_JSON` | Entire contents of the downloaded Google service-account JSON, including braces | Run time | **Yes** |
| `GA4_PROPERTY_ID` | `443444290` | Run time | No |
| `GA4_STREAM_ID` | `15781098262` | Run time | No |

Open `oekfbbucket-139a023884c6.json` locally and paste its contents directly into the encrypted variable value. Do not paste the filename, add extra wrapping quotes, or turn the JSON into a quoted JSON string. The JSON's escaped `\n` sequences inside `private_key` are correct; leave them as downloaded.

The backend parses this value in memory. Do not put the file in `Sources`, `Public`, the Git repository, a Docker image, or the frontend. The existing `CONNECTION_STRING` and configured backend MongoDB database are reused automatically; **no `GA4_MONGO_DATABASE` or `GOOGLE_APPLICATION_CREDENTIALS` setting is needed** for this native importer. Keep the backend's existing run command.

Google Cloud setup has already been completed:

- Project `oekfbbucket` has Google Analytics Data API enabled.
- `oekfb-analytics-reader@oekfbbucket.iam.gserviceaccount.com` has Viewer access to GA4 property `443444290`.

## Deploy and verify

Deploy the backend source changes, including `Package.swift` and `Package.resolved`. The new JWTKit 4.x dependency supports the existing Swift 5.8 Docker build. All existing dependency versions remain pinned.

Open backend **Runtime Logs**. Expected messages:

```text
GA4 importer configured: property 443444290, stream 15781098262; startup + hourly
GA4 import started (Homepage stream 15781098262)
GA4 import complete: 56 reports, ... rows saved to analytics_snapshots
```

The first import starts about **10 seconds after application boot**. Subsequent imports run at minute 5 each hour. A shared MongoDB lease prevents concurrent imports across backend replicas, renews during pagination, and expires after a crashed instance. Recent successful imports are skipped for five minutes to avoid duplicate imports during rolling deployments.

Using an existing authenticated **admin** bearer token:

```http
GET https://api.oekfb.eu/admin/analytics/status
Authorization: Bearer <existing-admin-token>

GET https://api.oekfb.eu/admin/analytics/today
Authorization: Bearer <existing-admin-token>
```

The status endpoint reports `state`, `last_success_at`, `last_error`, `reports_saved` and `rows_saved`. No Google secret or access token is exposed. Today returns the overview snapshot, or 404 before the first snapshot exists. Both routes use the backend's existing token authentication and admin-only middleware.

A successful import with **zero rows** means the Google connection worked but Google has no matching website data for those dates yet. Deploy the frontend tracking changes too, visit the production website, accept analytics, and check Google Analytics Realtime. Standard GA reporting can lag; successful backend authentication does not imply the frontend is already sending traffic.

## Storage and operation

- MongoDB collections: `analytics_snapshots` and `analytics_sync_state`. They are created automatically in the existing backend database; no new database or migration is required. Lookups and deduplication use MongoDB's built-in unique `_id` index.
- All reports filter to Homepage stream `15781098262`, excluding the app/admin streams in this shared property.
- Refreshes today and the preceding six calendar dates, with date selection based on Europe/Vienna. Google evaluates report dates in the property's reporting timezone, recorded on each snapshot; the live property currently reports `Etc/GMT-2` (fixed UTC+2), so winter day boundaries differ from Vienna until the property timezone is aligned.
- Reports: overview, pages, landing pages, sources, devices, countries, hours and events.
- Each complete report is atomically replaced, including empty reports. Failed fetches leave its previous snapshot intact; earlier completed reports in the same run remain saved. Sampling, thresholding and data-loss flags are retained.
- Metrics are stored as decimal strings. Never sum daily distinct users to produce monthly unique users; query the entire period separately when adding that dashboard.
- Aggregate history is retained until explicitly deleted; define the desired retention policy before accumulating long-term history. These are report snapshots, not individual event records.
- Invalid analytics configuration disables only this importer and logs a safe message; API/authentication failures do not take the website offline. `GA4_ENABLED=false` disables imports after redeployment.
- `google_http_403`: check Analytics Viewer permission/API enablement. `authentication_failed`: check the full JSON credential and whether the key was disabled/deleted. `invalid_configuration`: malformed JSON, missing credential or invalid IDs. `network_or_database_error`: check database connectivity and write permissions. Errors never print the credential or Google's response body.
- Report size is bounded below MongoDB's document limit. Very large reports fail safely and require a per-row storage design before raising limits.

## Previous Python importer

`tools/analytics` is the earlier optional standalone implementation. **Do not deploy or schedule it alongside this native importer.** The production path above replaces those instructions.

## Tests

```sh
swift test --filter GoogleAnalyticsTests
```

An opt-in read-only live smoke test can be run using `GA4_LIVE_CREDENTIALS_PATH` pointing to a local credential file. It requests all eight report types and never connects to MongoDB or prints credentials.
