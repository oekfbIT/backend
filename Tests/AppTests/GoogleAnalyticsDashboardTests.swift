@testable import App
import XCTVapor
import MongoKitten

final class GoogleAnalyticsDashboardTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-09-15T12:30:37Z")!
    let zone = TimeZone(identifier: "Europe/Vienna")!

    func testPresetsHaveConsistentMinuteBoundaries() throws {
        for preset in ["1h", "3h", "1d", "3d", "7d", "1m", "3m", "1y", "all"] {
            let range = try GA4DashboardRange.resolve(preset: preset, from: nil, to: nil, now: now, zone: zone)
            XCTAssertEqual(range.end, "2026-09-15T12:30:00Z")
            XCTAssertLessThan(range.start, range.end)
        }
        let hour = try GA4DashboardRange.resolve(preset: "1h", from: nil, to: nil, now: now, zone: zone)
        XCTAssertEqual(hour.start, "2026-09-15T11:30:00Z")
        XCTAssertEqual(hour.startMinute, "202609151330")
        XCTAssertEqual(hour.endMinute, "202609151430")
        XCTAssertEqual(hour.granularity, "dateHourMinute")
    }
    func testCustomInclusiveEndAndDST() throws {
        let range = try GA4DashboardRange.resolve(preset: "custom", from: "2026-03-29", to: "2026-03-29", now: now, zone: zone)
        XCTAssertEqual(range.start, "2026-03-28T23:00:00Z")
        XCTAssertEqual(range.end, "2026-03-29T22:00:00Z")
        XCTAssertEqual(range.endDate, "2026-03-29")
        XCTAssertFalse(range.provisional)
        for pair in [("2026-02-30", "2026-03-01"), ("2026-09-16", "2026-09-16"), ("2026-09-10", "2026-09-09"), ("2010-01-01", "2026-01-01")] {
            XCTAssertThrowsError(try GA4DashboardRange.resolve(preset: "custom", from: pair.0, to: pair.1, now: now, zone: zone))
        }
        XCTAssertThrowsError(try GA4DashboardRange.resolve(preset: "bad", from: nil, to: nil, now: now, zone: zone))
    }
    func testTotalsAndRatiosAreNotAddedFromBuckets() {
        let metrics = GA4Dashboard.metrics(["totalUsers": "3", "sessions": "5", "engagedSessions": "3", "screenPageViews": "12", "userEngagementDuration": "250"])
        XCTAssertEqual(metrics["totalUsers"], 3)
        XCTAssertEqual(metrics["viewsPerSession"], 2.4)
        XCTAssertEqual(metrics["engagementSecondsPerSession"], 50)
        XCTAssertEqual(metrics["bounceRate"], 0.4)
        XCTAssertNil(GA4Dashboard.metrics(["sessions": "0"])["bounceRate"])
    }
    func testWholeRangeFilterAndZeroDimensionsForUniqueTotals() throws {
        let range = try GA4DashboardRange.resolve(preset: "3h", from: nil, to: nil, now: now, zone: zone)
        let data = try range.request(configuration: GoogleAnalyticsTests().config(), report: GA4Dashboard.overview, limit: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["dimensions"] as? [Any])?.count, 0)
        let filter = try XCTUnwrap(object["dimensionFilter"] as? [String: Any])
        let expressions = try XCTUnwrap((filter["andGroup"] as? [String: Any])?["expressions"] as? [[String: Any]])
        XCTAssertEqual(expressions.count, 3)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("15781098262"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("LESS_THAN"))
    }
    func testDashboardRequiresAdminAuthentication() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try AdminController(path: "admin").boot(routes: app.routes)
        try app.test(.GET, "/admin/analytics/dashboard?range=7d") { response in XCTAssertEqual(response.status, .unauthorized) }
    }
    func testLiveDashboardWhenRequested() async throws {
        guard let path = Environment.get("GA4_LIVE_CREDENTIALS_PATH") else { throw XCTSkip("Opt-in live test") }
        let json = try String(contentsOfFile: path)
        let configuration = try XCTUnwrap(GA4Configuration.load { ["GA4_ENABLED": "true", "GA4_SERVICE_ACCOUNT_JSON": json][$0] })
        let app = Application(.testing)
        defer { app.shutdown() }
        let service = try GoogleAnalyticsService(configuration: configuration)
        let zone = try await service.dashboardZone(client: app.client)
        // Validate short-range minute filters and long-range deduplicated totals against Google.
        for preset in ["3h", "all"] {
            let range = try GA4DashboardRange.resolve(preset: preset, from: nil, to: nil, zone: zone)
            let payload = try await service.makeDashboard(client: app.client, range: range)
            XCTAssertEqual(payload.reports.count, 9)
            XCTAssertNotNil(payload.metrics["sessions"])
            let bson = try BSONEncoder().encode(GA4DashboardCache(_id: "test", savedAt: Date(), payload: payload))
            let decoded = try BSONDecoder().decode(GA4DashboardCache.self, from: bson)
            XCTAssertEqual(decoded.payload.range.start, payload.range.start)
            print("Validated dashboard range: \(preset); reporting timezone: \(zone.identifier)")
        }
    }
}
