@testable import App
import XCTVapor

final class GoogleAnalyticsRealtimeTests: XCTestCase {
    func testHomepageAndFiveMinuteFilter() throws {
        let report = GA4Report(name: "five", dimensions: [], metrics: ["activeUsers"])
        let data = try GA4Realtime.request(configuration: GoogleAnalyticsTests().config(), report: report, lastFive: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filter = try XCTUnwrap(object["dimensionFilter"] as? [String: Any])
        let expressions = try XCTUnwrap((filter["andGroup"] as? [String: Any])?["expressions"] as? [[String: Any]])
        XCTAssertEqual(expressions.count, 2)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("15781098262"))
        let minute = try XCTUnwrap(expressions[1]["filter"] as? [String: Any])
        XCTAssertEqual(minute["fieldName"] as? String, "minutesAgo")
        XCTAssertEqual(((minute["numericFilter"] as? [String: Any])?["value"] as? [String: String])?["int64Value"], "4")
    }
    func testRealtimeRequiresAuthentication() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try AdminController(path: "admin").boot(routes: app.routes)
        try app.test(.GET, "/admin/analytics/realtime") { XCTAssertEqual($0.status, .unauthorized) }
    }
    func testLiveRealtimeAndCacheWhenRequested() async throws {
        guard let path = Environment.get("GA4_LIVE_CREDENTIALS_PATH") else { throw XCTSkip("Opt-in live test") }
        let json = try String(contentsOfFile: path)
        let config = try XCTUnwrap(GA4Configuration.load { ["GA4_ENABLED":"true", "GA4_SERVICE_ACCOUNT_JSON":json][$0] })
        let app = Application(.testing)
        defer { app.shutdown() }
        let service = try GoogleAnalyticsService(configuration: config)
        let result = try await service.realtime(client: app.client)
        XCTAssertGreaterThanOrEqual(result.activeUsers30, result.activeUsers5)
        XCTAssertLessThanOrEqual(result.events.count, 5)
        XCTAssertLessThanOrEqual(result.minutes.count, 30)
        let cached = try await service.realtime(client: app.client)
        XCTAssertEqual(cached.fetchedAt, result.fetchedAt)
        print("Validated Google Realtime: \(result.activeUsers30) active users, \(result.eventCount30) events")
    }
}
