"""Read-only GA4 reporting importer. Writes aggregate snapshots to MongoDB.

Run hourly with an external scheduler: python sync.py
Authentication uses Google's Application Default Credentials (ADC).
"""
import hashlib
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

PROPERTY_ID = "443444290"
STREAM_ID = "15781098262"
REPORTS = {
    "overview": ([], ["totalUsers", "newUsers", "sessions", "engagedSessions", "screenPageViews", "userEngagementDuration", "eventCount"]),
    "pages": (["pagePath"], ["screenPageViews", "totalUsers", "userEngagementDuration"]),
    "landing_pages": (["landingPage"], ["sessions", "engagedSessions", "totalUsers"]),
    "sources": (["sessionSource", "sessionMedium"], ["sessions", "engagedSessions", "totalUsers"]),
    "devices": (["deviceCategory"], ["sessions", "totalUsers"]),
    "countries": (["country"], ["sessions", "totalUsers"]),
    "hours": (["hour"], ["sessions", "totalUsers"]),
    "events": (["eventName"], ["eventCount", "totalUsers"]),
}


def snapshot_id(property_id, stream_id, report, day):
    return hashlib.sha256(json.dumps([property_id, stream_id, report, day]).encode()).hexdigest()


def report_request(property_id, stream_id, report, day, offset=0):
    dimensions, metrics = REPORTS[report]
    return {
        "property": f"properties/{property_id}",
        "date_ranges": [{"start_date": day, "end_date": day}],
        "dimensions": [{"name": d} for d in dimensions],
        "metrics": [{"name": m} for m in metrics],
        "dimension_filter": {"filter": {"field_name": "streamId", "string_filter": {"match_type": "EXACT", "value": stream_id}}},
        "order_bys": [{"dimension": {"dimension_name": d}} for d in dimensions],
        "limit": 10000,
        "offset": offset,
        "return_property_quota": True,
    }


def fetch_report(client, request):
    # Page through all rows before replacing a snapshot; partial responses never overwrite it.
    rows = []
    thresholded = False
    sampled = False
    while True:
        response = client.run_report(request=request, timeout=60)
        dimensions = [h.name for h in response.dimension_headers]
        metrics = [h.name for h in response.metric_headers]
        thresholded |= bool(response.metadata.subject_to_thresholding)
        sampled |= bool(response.metadata.sampling_metadatas)
        for row in response.rows:
            rows.append({
                "dimensions": dict(zip(dimensions, (v.value for v in row.dimension_values))),
                # Keep Google's decimal strings intact; dashboard chooses numeric formatting.
                "metrics": dict(zip(metrics, (v.value for v in row.metric_values))),
            })
        if len(rows) >= response.row_count:
            break
        if not response.rows:
            raise RuntimeError("Incomplete Analytics pagination")
        request = {**request, "offset": len(rows)}
    return rows, thresholded, sampled


def sync(client, collection, property_id, stream_id, today, lookback=7):
    failures = 0
    for days_ago in range(lookback):
        day = (today - timedelta(days=days_ago)).isoformat()
        for report in REPORTS:
            try:
                rows, thresholded, sampled = fetch_report(client, report_request(property_id, stream_id, report, day))
                document = {
                    "_id": snapshot_id(property_id, stream_id, report, day),
                    "property_id": property_id, "stream_id": stream_id,
                    "report": report, "date": day, "timezone": "Europe/Vienna",
                    "fetched_at": datetime.now(timezone.utc),
                    "provisional": days_ago < 3, "thresholded": thresholded,
                    "sampled": sampled, "rows": rows,
                    "schema_version": 1,
                }
                # Mongo's unique _id + atomic replacement avoids duplicate rows on retries.
                collection.replace_one({"_id": document["_id"]}, document, upsert=True)
            except Exception as error:
                # Do not print exception bodies; drivers may include credentials or report data.
                logging.error("Analytics sync failed: report=%s date=%s type=%s", report, day, type(error).__name__)
                failures += 1
    if failures:
        raise RuntimeError(f"{failures} analytics reports failed; previous snapshots retained")


def main():
    from google.analytics.data_v1beta import BetaAnalyticsDataClient
    from pymongo import MongoClient

    property_id = os.getenv("GA4_PROPERTY_ID", PROPERTY_ID)
    stream_id = os.getenv("GA4_STREAM_ID", STREAM_ID)
    if not property_id.isdigit() or not stream_id.isdigit():
        raise ValueError("GA4 property and stream IDs must be numeric")
    mongo_uri = os.environ["CONNECTION_STRING"]
    database_name = os.environ["GA4_MONGO_DATABASE"]
    client = BetaAnalyticsDataClient()
    with MongoClient(mongo_uri, serverSelectionTimeoutMS=15000) as mongo:
        collection = mongo[database_name]["analytics_snapshots"]
        collection.create_index([("property_id", 1), ("stream_id", 1), ("report", 1), ("date", 1)])
        sync(client, collection, property_id, stream_id, datetime.now(ZoneInfo("Europe/Vienna")).date())
    logging.info("Analytics snapshot sync complete")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    try:
        main()
    except Exception as error:
        logging.error("Analytics importer stopped: %s", type(error).__name__)
        raise SystemExit(1)
