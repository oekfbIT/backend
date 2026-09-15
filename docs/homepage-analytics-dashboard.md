# Homepage Analytics dashboard

## Deploy

1. Deploy BE with `Sources/App/Services/GoogleAnalyticsDashboard.swift` and the changes to `GoogleAnalyticsService.swift`.
2. Keep the existing `GA4_ENABLED`, encrypted `GA4_SERVICE_ACCOUNT_JSON`, `GA4_PROPERTY_ID` and `GA4_STREAM_ID` runtime variables. No new secret, npm package, worker or database is needed.
3. Deploy the admin frontend and open **Administration → Homepage → Homepage Analytics** (`/admin/homepage-analytics`).
4. Select a range. Successful empty Google reports display an explicit empty state; failures display an error instead of fabricated zero metrics. A 404 means the backend route is not deployed; 503 means analytics is disabled/not configured; 401/403 requires an admin login.

The browser only calls the authenticated backend. Google credentials stay on the server. The same selected range drives all historical cards, charts and tables; realtime uses its own fixed windows.

## API and data contract

`GET /admin/analytics/dashboard?range=7d`

Supported ranges: `1h`, `3h`, `1d`, `3d`, `7d`, `1m`, `3m`, `1y`, `all`, `custom`.

Custom: `?range=custom&from=2026-09-01&to=2026-09-14`. Dates use the GA property's reporting timezone. Both selected dates are included, with today capped to the last complete minute. Presets are trailing windows; month/year presets use calendar subtraction. The response specifies the exact start/end (exclusive), property timezone, and chart granularity. All time requests all available Google reporting history from 2015-08-14; it cannot reconstruct visits before tracking existed.

Response schema version 1:

- `property_id`, `stream_id`: fixed by backend configuration; every Google report filters to the Homepage stream.
- `range`: `preset`, ISO `start` / `end`, `time_zone`, `granularity`, `provisional`, `start_date`, `end_date`, `start_minute`, `end_minute`.
- `fetched_at`, `cached`: when Google was queried and whether the five-minute cache was used.
- `metrics`: whole-range totals (`totalUsers`, `activeUsers`, `newUsers`, `returningUsers`, `sessions`, `engagedSessions`, `screenPageViews`, `userEngagementDuration`, `eventCount`, `keyEvents`) and backend-calculated ratios (`sessionsPerUser`, `viewsPerSession`, `engagementSecondsPerSession`, `engagementRate`, `bounceRate`). Metric dictionary keys intentionally match Google camelCase names. Undefined ratios with zero denominators are omitted and shown as a dash.
- `reports`: `overview`, `visitors`, `trend`, `pages`, `landing_pages`, `sources`, `devices`, `countries`, `events`. Each has `rows` (`dimensions` and `metrics` dictionaries), `row_count`, `limited`, `thresholded`, `sampled`, `data_loss`. Google row metric values are decimal strings.

Returning users come from Google's supported `newVsReturning=returning` breakdown, not a nonexistent `returningUsers` API metric. New and returning users can overlap across the selected period; these values are not a mutually exclusive pie chart.

## Calculation and freshness

- Google computes distinct users for the whole selected range. Daily/monthly unique-user buckets must never be summed into a range total. The backend computes ratios once; the admin formats them without recomputing totals.
- Trend resolution: minute (up to three hours), hour (up to three days), day (up to 100 days), month (longer). Missing time buckets are displayed as zero; quality flags remain visible. A maximum of 500 chronological buckets is enforced.
- Tables show the top 20 rows sorted by their count, with an explicit limit badge when Google has more rows. Device chart shows sessions.
- Current/last-72-hour data is provisional. Last hour and last three hours use Core Reporting minute filters; they are **not realtime**. Google processing latency can leave them empty. The Realtime link opens Google's live report separately.
- Time filters use Google's property-local `dateHourMinute` dimension. During a daylight-saving fall-back hour, repeated local minute labels cannot be distinguished by this dimension. The current property reports fixed UTC+2 (`Etc/GMT-2`).
- `analytics_dashboard_cache` stores one complete response per preset in the backend MongoDB (at most ten records per property/stream). The custom slot is reused and checks requested dates before a cache hit. Entries refresh on demand after five minutes. Concurrent identical requests are coalesced per backend instance; up to three different queries run per instance.
- Cache writes are checked for MongoDB errors. A partial Google fetch is never published as a complete response. Errors are sanitized. Responses send `Cache-Control: no-store` to avoid browser/proxy caching of authenticated reports.
- The existing hourly `analytics_snapshots` importer remains available as daily history. Dashboard totals use separate Google range queries so they remain deduplicated. The dashboard does not infer exact totals by adding daily snapshots.

## Verification

- `swift test --jobs 4 --filter GoogleAnalytics` in BE.
- Set `GA4_LIVE_CREDENTIALS_PATH` to a local service-account file for optional live read-only tests; they validate short and all-time requests and BSON round-tripping without connecting to MongoDB.
- In the admin: `CI=true npm test -- --watchAll=false --runInBand --testPathPattern=homepageAnalytics` and `GENERATE_SOURCEMAP=false npm run build`.
- Local browser preview used synthetic data, clearly labelled, to check the rendered chart and layout. Preview data is not part of the application or production bundle.
- Verify production MongoDB cache writes and authenticated endpoint access after deployment.

## Realtime activity

`GET /admin/analytics/realtime` requires the same admin authentication and existing GA4 runtime settings. Deploy the backend (including `GoogleAnalyticsRealtime.swift`) before the admin frontend.

- The separate **Live-Aktivität** panel shows active users over 30 and 5 minutes, page views and events over 30 minutes, a per-minute activity chart, and the five most frequent events. Historical range selections do not change these windows.
- Reports use Google's Realtime API and filter to the configured Homepage stream. Whole-window distinct user totals are queried directly, never summed from minute buckets.
- Response schema version 1 contains `schema_version`, `fetched_at`, `active_users30`, `active_users5`, `page_views30`, `event_count30`, `minutes`, and `events`. Row dictionaries use Google dimension/metric names.
- The backend caches complete responses in memory for 30 seconds and coalesces concurrent requests. Realtime does not require MongoDB or alter the hourly snapshot importer.
- The visible admin page refreshes realtime once per minute. Google can report activity with a short delay. A failed refresh keeps the last successful values with their timestamp and a visible error; an initial failure is not shown as zero traffic.
- Historical freshness notices are short inline text with expandable details. Report definitions are also collapsed by default.
- Realtime tests cover request filters, authentication, optional live Google reads, caching, polling, error states, and cleanup.
