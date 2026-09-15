@testable import App
import XCTVapor
import MongoKitten

final class GoogleAnalyticsTests: XCTestCase {
    func config() throws -> GA4Configuration {
        let pemURL = try XCTUnwrap(Bundle.module.url(forResource: "ga4-test-key", withExtension: "txt", subdirectory: "Fixtures"))
        let pem = try String(contentsOf: pemURL)
        let data = try JSONSerialization.data(withJSONObject: ["type": "service_account", "client_email": "test@oekfbbucket.iam.gserviceaccount.com", "private_key": pem])
        let json = String(decoding: data, as: UTF8.self)
        return try XCTUnwrap(GA4Configuration.load { ["GA4_ENABLED": "true", "GA4_SERVICE_ACCOUNT_JSON": json][$0] })
    }

    func testDisabledDoesNotRequireCredential() throws {
        XCTAssertNil(try GA4Configuration.load { _ in nil })
        XCTAssertThrowsError(try GA4Configuration.load { $0 == "GA4_ENABLED" ? "true" : nil })
    }

    func testCredentialsAndIDsAreValidated() throws {
        let configuration = try config()
        XCTAssertEqual(configuration.propertyID, "443444290")
        XCTAssertEqual(configuration.streamID, "15781098262")
        XCTAssertFalse(GA4Configuration.validID("443444290/other"))
        XCTAssertFalse(GA4Configuration.validID("１２３"))
        XCTAssertFalse(GA4Configuration.validID(""))
        XCTAssertThrowsError(try GA4Configuration.load { ["GA4_ENABLED": "true", "GA4_SERVICE_ACCOUNT_JSON": "not JSON"][$0] })
    }

    func testEveryReportFiltersToHomepageAndUsesGoogleCamelCase() throws {
        for report in GA4Report.all {
            let data = try report.request(configuration: config(), day: "2026-09-15", offset: 10000)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let filter = try XCTUnwrap((object["dimensionFilter"] as? [String: Any])?["filter"] as? [String: Any])
            XCTAssertEqual(filter["fieldName"] as? String, "streamId")
            XCTAssertEqual((filter["stringFilter"] as? [String: String])?["value"], "15781098262")
            XCTAssertEqual(object["offset"] as? Int, 10000)
            XCTAssertNotNil(object["dateRanges"])
            XCTAssertNil(object["date_ranges"])
        }
    }

    func testViennaDayAroundMidnightAndDST() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T22:30:00Z"))
        XCTAssertEqual(GA4Configuration.day(date), "2026-03-30")
        XCTAssertEqual(GA4Configuration.day(date, daysAgo: 1), "2026-03-29")
    }

    func testTokenExchangeCachingAndResponseDecoding() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        let client = GA4MockClient(eventLoop: app.eventLoopGroup.next())
        let service = try GoogleAnalyticsService(configuration: config())
        for _ in 0..<2 {
            let result = try await service.fetchPage(client: client, report: GA4Report.all[0], day: "2026-09-15", offset: 0)
            XCTAssertEqual(result.rowCount, 0)
        }
        XCTAssertEqual(client.requests.filter { $0.url.host == "oauth2.googleapis.com" }.count, 1)
        let tokenRequest = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(tokenRequest.headers.contentType, .urlEncodedForm)
        let body = String(buffer: try XCTUnwrap(tokenRequest.body))
        XCTAssertTrue(body.hasPrefix("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="))
        XCTAssertFalse(body.contains("PRIVATE KEY"))
        XCTAssertEqual(client.requests.last?.headers.bearerAuthorization?.token, "test-token")
    }

    func testPermissionFailureHasSafeErrorAndDoesNotRetry() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        let client = GA4MockClient(eventLoop: app.eventLoopGroup.next(), reportStatus: .forbidden)
        let service = try GoogleAnalyticsService(configuration: config())
        do {
            _ = try await service.fetchPage(client: client, report: GA4Report.all[0], day: "2026-09-15", offset: 0)
            XCTFail("Expected denied access")
        } catch let error as GA4Error { XCTAssertEqual(error.safeCode, "google_http_403") }
        XCTAssertEqual(client.requests.count, 2)
    }

    func testMongoWriteErrorsAreNotReportedAsSuccessfulImports() throws {
        let reply = try BSONDecoder().decode(UpdateReply.self, from: ["ok": 1, "n": 0, "nModified": 0, "writeErrors": [["index": 0, "code": 13, "errmsg": "denied"] as Document]])
        XCTAssertThrowsError(try GoogleAnalyticsService.checkWrite(reply))
    }

    func testSnapshotRoundTripsThroughMongoEncoding() throws {
        let snapshot = GA4Snapshot(id: "ga4:443444290:15781098262:overview:2026-09-15", propertyID: "443444290", streamID: "15781098262", report: "overview", date: "2026-09-15", fetchedAt: Date(), provisional: true, thresholded: false, sampled: false, dataLossFromOtherRow: false, reportingTimeZone: "Europe/Vienna", rows: [.init(dimensions: [:], metrics: ["sessions": "12"])])
        let encoded = try BSONEncoder().encode(snapshot)
        let decoded = try BSONDecoder().decode(GA4Snapshot.self, from: encoded)
        XCTAssertEqual(decoded.id, snapshot.id)
        XCTAssertEqual(decoded.rows.first?.metrics["sessions"], "12")
    }

    func testEmptyGoogleStreamOmitsHeadersAndRows() throws {
        let data = Data(#"{"kind":"analyticsData#runReport","metadata":{"timeZone":"Europe/Vienna"},"propertyQuota":{}}"#.utf8)
        let response = try JSONDecoder().decode(GA4ReportResponse.self, from: data)
        XCTAssertNil(response.metricHeaders)
        XCTAssertTrue((response.rows ?? []).isEmpty)
    }

    func testAnalyticsEndpointsRequireAuthentication() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try app.register(collection: AdminController(path: "admin"))
        try app.test(.GET, "admin/analytics/status") { XCTAssertEqual($0.status, .unauthorized) }
        try app.test(.GET, "admin/analytics/today") { XCTAssertEqual($0.status, .unauthorized) }
    }

    func testLiveGoogleCredentialIfRequested() async throws {
        guard let path = Environment.get("GA4_LIVE_CREDENTIALS_PATH") else { throw XCTSkip("Opt-in read-only Google smoke test") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = String(decoding: data, as: UTF8.self)
        let configuration = try XCTUnwrap(GA4Configuration.load { ["GA4_ENABLED": "true", "GA4_SERVICE_ACCOUNT_JSON": json][$0] })
        XCTAssertEqual(configuration.credential.clientEmail, "oekfb-analytics-reader@oekfbbucket.iam.gserviceaccount.com")
        let app = Application(.testing)
        app.logger.logLevel = .critical
        defer { app.shutdown() }
        let service = try GoogleAnalyticsService(configuration: configuration)
        for report in GA4Report.all {
            let response = try await service.fetchPage(client: app.client, report: report, day: GA4Configuration.day(Date(), daysAgo: 1), offset: 0)
            if !(response.rows ?? []).isEmpty { XCTAssertEqual(response.metricHeaders?.map(\.name), report.metrics) }
            print("Validated Google report: \(report.name); timezone: \(response.metadata?.timeZone ?? "unspecified"); rows: \(response.rowCount ?? 0)")
        }
    }
}

private final class GA4MockClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    let reportStatus: HTTPStatus
    private let lock = NSLock()
    private var captured: [ClientRequest] = []
    var requests: [ClientRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    init(eventLoop: EventLoop, reportStatus: HTTPStatus = .ok) { self.eventLoop = eventLoop; self.reportStatus = reportStatus }
    func delegating(to eventLoop: EventLoop) -> Client { self }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        lock.lock(); captured.append(request); lock.unlock()
        let isToken = request.url.host == "oauth2.googleapis.com"
        let body = isToken ? #"{"access_token":"test-token","expires_in":3600}"# : #"{"metricHeaders":[{"name":"totalUsers"}],"rowCount":0,"metadata":{"timeZone":"Europe/Vienna"}}"#
        return eventLoop.makeSucceededFuture(.init(status: isToken ? .ok : reportStatus, body: ByteBuffer(string: body)))
    }
}
