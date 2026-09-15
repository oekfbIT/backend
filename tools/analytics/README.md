# Homepage analytics importer

Runs separately from the Vapor HTTP process and writes aggregate reports to the same MongoDB database. A small Python job uses Google's official SDK for token refresh/retries rather than introducing custom Google authentication into Swift. No public analytics ingest endpoint is added. The worker is not enabled by adding these files.

## Configuration

- `GA4_PROPERTY_ID=443444290`
- `GA4_STREAM_ID=15781098262` (Homepage only; this property also contains app/admin streams)
- `CONNECTION_STRING`: secret MongoDB URI already used by the backend.
- `GA4_MONGO_DATABASE`: explicit database name used by Vapor; do not guess from a fallback URI.
- `GOOGLE_APPLICATION_CREDENTIALS`: path to a mounted service-account JSON credential or workload identity configuration. Never commit the credential.

Enable **Google Analytics Data API** in the Google Cloud project. Grant the service account **Viewer** on Analytics property `443444290`. Google Cloud IAM roles alone do not grant access to Analytics reports. Prefer workload identity where supported; otherwise mount a service-account key read-only as a deployment secret accessible to the container user.

## Run

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python sync.py
```

Or build this directory with its Dockerfile and configure a **single hourly scheduled job** to run the container with the environment/secrets above. Use the existing deployment scheduler; do not run one importer per Vapor replica. An exit code of 1 indicates a failed/incomplete sync and should alert the operator. No production credentials are included here.

## Data contract

Collection: `analytics_snapshots`. One document per property + stream + report + local date. `rows` contains dimensions and metrics (decimal strings). Each complete report is replaced atomically, including empty reports; retries cannot add duplicate snapshots. Failed fetches retain the previous snapshot. Eight report types cover overview, pages, landing pages, source/medium, devices, countries, hours, and events. Every request filters to the Homepage stream.

Every run refreshes today and the six previous dates in Europe/Vienna. Recent snapshots carry `provisional=true`; older data can still be revised by Google. Snapshots expose sampling/thresholding flags and `fetched_at`; consumers must show freshness. Overview metrics do not need to equal sums of dimensional reports. **Never sum daily distinct users into weekly/monthly users**; request a dedicated whole-period report when implementing that dashboard.

MongoDB has a 16 MiB document limit. At unexpectedly large per-day report sizes, replacement fails safely and retains the previous snapshot; move to per-row storage with versioned report commits before reaching that scale. Set a deliberate retention/deletion policy before activation; this worker intentionally does not silently delete saved history.

These are aggregated snapshots, not an event archive or trigger queue. Reliable registration workflows remain in the backend's registration handler. BigQuery export is a separate optional feature, not enabled by this worker.

## Validation

`python3 -m unittest discover -s . -p 'test_*.py'` checks stream isolation, pagination, idempotent replacement and failed-fetch retention without connecting to Google or MongoDB. Live authentication and database permissions still require a deployment smoke test.
