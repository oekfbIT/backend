import Foundation
import Vapor
import Fluent
import FluentMongoDriver
import MongoKitten
import JWTKit
import Queues

struct GA4Configuration {
    let propertyID: String
    let streamID: String
    let credential: GA4Credential

    static func load(environment: (String) -> String? = Environment.get) throws -> GA4Configuration? {
        guard environment("GA4_ENABLED") == "true" else { return nil }
        guard let json = environment("GA4_SERVICE_ACCOUNT_JSON"), !json.isEmpty else {
            throw GA4Error.configuration
        }
        let property = environment("GA4_PROPERTY_ID") ?? "443444290"
        let stream = environment("GA4_STREAM_ID") ?? "15781098262"
        guard validID(property), validID(stream), let data = json.data(using: .utf8),
              let credential = try? JSONDecoder().decode(GA4Credential.self, from: data),
              credential.type == "service_account",
              credential.clientEmail.hasSuffix(".iam.gserviceaccount.com"),
              credential.privateKey.contains("-----BEGIN PRIVATE KEY-----") else {
            throw GA4Error.configuration
        }
        return .init(propertyID: property, streamID: stream, credential: credential)
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    var key: String { "ga4:\(propertyID):\(streamID)" }
    static func day(_ date: Date, daysAgo: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: date)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}

struct GA4Credential: Decodable {
    let type: String
    let clientEmail: String
    let privateKey: String
    enum CodingKeys: String, CodingKey {
        case type, clientEmail = "client_email", privateKey = "private_key"
    }
}

enum GA4Error: Error {
    case configuration, authentication, http(Int), invalidResponse, leaseLost, oversizedReport
    var safeCode: String {
        switch self {
        case .configuration: return "invalid_configuration"
        case .authentication: return "authentication_failed"
        case .http(let status): return "google_http_\(status)"
        case .invalidResponse: return "invalid_google_response"
        case .leaseLost: return "lease_lost"
        case .oversizedReport: return "report_too_large"
        }
    }
}

private struct GA4Assertion: JWTPayload {
    let iss: String
    let scope: String
    let aud: String
    let iat: IssuedAtClaim
    let exp: ExpirationClaim
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}

struct GA4Report {
    let name: String
    let dimensions: [String]
    let metrics: [String]
    static let all: [GA4Report] = [
        .init(name: "overview", dimensions: [], metrics: ["totalUsers", "newUsers", "sessions", "engagedSessions", "screenPageViews", "userEngagementDuration", "eventCount"]),
        .init(name: "pages", dimensions: ["pagePath"], metrics: ["screenPageViews", "totalUsers", "userEngagementDuration"]),
        .init(name: "landing_pages", dimensions: ["landingPage"], metrics: ["sessions", "engagedSessions", "totalUsers"]),
        .init(name: "sources", dimensions: ["sessionSource", "sessionMedium"], metrics: ["sessions", "totalUsers"]),
        .init(name: "devices", dimensions: ["deviceCategory"], metrics: ["sessions", "totalUsers"]),
        .init(name: "countries", dimensions: ["country"], metrics: ["sessions", "totalUsers"]),
        .init(name: "hours", dimensions: ["hour"], metrics: ["sessions", "totalUsers"]),
        .init(name: "events", dimensions: ["eventName"], metrics: ["eventCount", "totalUsers"])
    ]
    func request(configuration: GA4Configuration, day: String, offset: Int) throws -> Data {
        // Dedicated encoder avoids the application's snake_case ContentConfiguration.
        try JSONSerialization.data(withJSONObject: [
            "dateRanges": [["startDate": day, "endDate": day]],
            "dimensions": dimensions.map { ["name": $0] },
            "metrics": metrics.map { ["name": $0] },
            "dimensionFilter": ["filter": ["fieldName": "streamId", "stringFilter": ["matchType": "EXACT", "value": configuration.streamID]]],
            "orderBys": dimensions.map { ["dimension": ["dimensionName": $0]] },
            "offset": offset, "limit": 10000, "returnPropertyQuota": true
        ])
    }
}

struct GA4ReportResponse: Decodable {
    struct Header: Decodable { let name: String }
    struct Value: Decodable { let value: String }
    struct Row: Decodable { let dimensionValues: [Value]?; let metricValues: [Value] }
    struct Metadata: Decodable {
        struct Sampling: Decodable { let samplesReadCount: String?; let samplingSpaceSize: String? }
        let subjectToThresholding: Bool?
        let dataLossFromOtherRow: Bool?
        let samplingMetadatas: [Sampling]?
        let timeZone: String?
    }
    let dimensionHeaders: [Header]?
    let metricHeaders: [Header]?
    let rows: [Row]?
    let rowCount: Int?
    let metadata: Metadata?
}

struct GA4Snapshot: Content {
    let id: String
    let propertyID: String
    let streamID: String
    let report: String
    let date: String
    let fetchedAt: Date
    let provisional: Bool
    let thresholded: Bool
    let sampled: Bool
    let dataLossFromOtherRow: Bool
    let reportingTimeZone: String
    let rows: [Row]
    struct Row: Content { let dimensions: [String: String]; let metrics: [String: String] }
    enum CodingKeys: String, CodingKey {
        case id = "_id", propertyID = "property_id", streamID = "stream_id", report, date
        case fetchedAt = "fetched_at", provisional, thresholded, sampled, rows
        case dataLossFromOtherRow = "data_loss_from_other_row", reportingTimeZone = "reporting_time_zone"
    }
}

struct GA4SyncStatus: Content {
    var enabled: Bool
    var state: String
    var lastStartedAt: Date?
    var lastSuccessAt: Date?
    var lastFinishedAt: Date?
    var lastError: String?
    var reportsSaved: Int?
    var rowsSaved: Int?
}

actor GoogleAnalyticsService {
    let configuration: GA4Configuration
    private let signer: JWTSigner
    private var token: (value: String, expires: Date)?
    private var running = false
    var realtimeCache: (expires: Date, payload: GA4Realtime)?
    var realtimePending: Task<GA4Realtime, Error>?
    var dashboardTimeZone: TimeZone?
    var dashboardPending: [String: Task<GA4Dashboard, Error>] = [:]

    init(configuration: GA4Configuration) throws {
        self.configuration = configuration
        do { signer = try .rs256(key: .private(pem: configuration.credential.privateKey)) }
        catch { throw GA4Error.configuration }
    }

    func mongo(_ app: Application) throws -> MongoDatabase {
        guard let database = app.db as? MongoDatabaseRepresentable else { throw GA4Error.configuration }
        return database.raw
    }

    private func accessToken(client: Client) async throws -> String {
        if let token = token, token.expires > Date().addingTimeInterval(60) { return token.value }
        let now = Date()
        let assertion = try signer.sign(GA4Assertion(iss: configuration.credential.clientEmail, scope: "https://www.googleapis.com/auth/analytics.readonly", aud: "https://oauth2.googleapis.com/token", iat: .init(value: now), exp: .init(value: now.addingTimeInterval(3600))))
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
        let response = try await client.post("https://oauth2.googleapis.com/token") { request in
            request.timeout = .seconds(30)
            request.headers.contentType = .urlEncodedForm
            request.body = ByteBuffer(string: body)
        }
        guard response.status == .ok, let buffer = response.body else { throw GA4Error.authentication }
        struct TokenResponse: Decodable { let access_token: String; let expires_in: Int }
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: Data(buffer.readableBytesView)), !result.access_token.isEmpty else { throw GA4Error.authentication }
        token = (result.access_token, now.addingTimeInterval(TimeInterval(result.expires_in)))
        return result.access_token
    }

    // Also used by an opt-in test to validate the downloaded credential without touching MongoDB.
    func fetchPage(client: Client, report: GA4Report, day: String, offset: Int) async throws -> GA4ReportResponse {
        let body = try report.request(configuration: configuration, day: day, offset: offset)
        return try await fetchReport(client: client, report: report, body: body)
    }

    func fetchReport(client: Client, report: GA4Report, body: Data, realtime: Bool = false) async throws -> GA4ReportResponse {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let bearer = try await accessToken(client: client)
            let method = realtime ? "runRealtimeReport" : "runReport"
            let response = try await client.post(URI(string: "https://analyticsdata.googleapis.com/v1beta/properties/\(configuration.propertyID):\(method)")) { request in
                request.timeout = .seconds(60)
                request.headers.bearerAuthorization = .init(token: bearer)
                request.headers.contentType = .json
                request.body = ByteBuffer(data: body)
            }
            if response.status == .ok {
                guard let buffer = response.body,
                      let decoded = try? JSONDecoder().decode(GA4ReportResponse.self, from: Data(buffer.readableBytesView)) else { throw GA4Error.invalidResponse }
                // GA omits headers and rows entirely when the stream has no data.
                if !(decoded.rows ?? []).isEmpty {
                    guard decoded.metricHeaders?.map(\.name) == report.metrics,
                          (decoded.dimensionHeaders ?? []).map(\.name) == report.dimensions else { throw GA4Error.invalidResponse }
                }
                return decoded
            }
            if response.status == .unauthorized { token = nil }
            let retryable = response.status == .unauthorized || response.status.code == 429 || response.status.code >= 500
            guard retryable && attempt < 2 else { throw GA4Error.http(Int(response.status.code)) }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
        }
        throw GA4Error.invalidResponse
    }

    private func renew(_ database: MongoDatabase, owner: String) async throws {
        let reply = try await database["analytics_sync_state"].findOneAndUpdate(
            where: ["_id": configuration.key, "owner": owner],
            to: ["$set": ["lease_until": Date().addingTimeInterval(300)]], returnValue: .modified
        ).execute().get()
        guard reply.value != nil else { throw GA4Error.leaseLost }
    }

    func run(app: Application) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let owner = UUID().uuidString
        var acquired = false
        var reportsSaved = 0
        var rowsSaved = 0
        do {
            let database = try mongo(app)
            let states = database["analytics_sync_state"]
            // Only _id is unique; concurrent first inserts use the same immutable identity.
            let seed = try await states.upsert(["$setOnInsert": ["_id": configuration.key, "lease_until": Date.distantPast, "next_run_at": Date.distantPast, "enabled": true, "state": "ready"] as Document], where: ["_id": configuration.key]).get()
            try Self.checkWrite(seed, allowDuplicate: true)
            let now = Date()
            let lease = try await states.findOneAndUpdate(
                where: ["_id": configuration.key, "lease_until": ["$lte": now], "next_run_at": ["$lte": now]],
                to: ["$set": ["owner": owner, "lease_until": now.addingTimeInterval(300), "state": "running", "lastStartedAt": now, "lastError": ""] as Document], returnValue: .modified
            ).execute().get()
            guard lease.value != nil else { return }
            acquired = true
            app.logger.info("GA4 import started (Homepage stream \(configuration.streamID))")
            for daysAgo in 0..<7 {
                let day = GA4Configuration.day(now, daysAgo: daysAgo)
                for report in GA4Report.all {
                    var rows: [GA4Snapshot.Row] = []
                    var thresholded = false
                    var sampled = false
                    var dataLoss = false
                    var reportingZone = "Europe/Vienna"
                    repeat {
                        try Task.checkCancellation()
                        try await renew(database, owner: owner)
                        let response = try await fetchPage(client: app.client, report: report, day: day, offset: rows.count)
                        thresholded = thresholded || response.metadata?.subjectToThresholding == true
                        sampled = sampled || !(response.metadata?.samplingMetadatas ?? []).isEmpty
                        dataLoss = dataLoss || response.metadata?.dataLossFromOtherRow == true
                        reportingZone = response.metadata?.timeZone ?? reportingZone
                        let dimensionNames = (response.dimensionHeaders ?? []).map(\.name)
                        let metricNames = (response.metricHeaders ?? []).map(\.name)
                        for row in response.rows ?? [] {
                            guard (row.dimensionValues ?? []).count == dimensionNames.count, row.metricValues.count == metricNames.count else { throw GA4Error.invalidResponse }
                            rows.append(.init(dimensions: Dictionary(uniqueKeysWithValues: zip(dimensionNames, (row.dimensionValues ?? []).map(\.value))), metrics: Dictionary(uniqueKeysWithValues: zip(metricNames, row.metricValues.map(\.value)))))
                        }
                        guard rows.count <= 50000 else { throw GA4Error.oversizedReport }
                        if rows.count >= (response.rowCount ?? 0) { break }
                        guard !(response.rows ?? []).isEmpty else { throw GA4Error.invalidResponse }
                    } while true
                    let id = "\(configuration.key):\(report.name):\(day)"
                    let snapshot = GA4Snapshot(id: id, propertyID: configuration.propertyID, streamID: configuration.streamID, report: report.name, date: day, fetchedAt: Date(), provisional: daysAgo < 3, thresholded: thresholded, sampled: sampled, dataLossFromOtherRow: dataLoss, reportingTimeZone: reportingZone, rows: rows)
                    // Bound one atomic MongoDB document below its 16 MiB limit.
                    guard try JSONEncoder().encode(snapshot).count < 8_000_000 else { throw GA4Error.oversizedReport }
                    try await renew(database, owner: owner)
                    let write = try await database["analytics_snapshots"].upsertEncoded(snapshot, where: ["_id": id]).get()
                    try Self.checkWrite(write)
                    reportsSaved += 1
                    rowsSaved += rows.count
                }
            }
            let finished = try await states.updateOne(where: ["_id": configuration.key, "owner": owner], to: ["$set": ["state": "success", "lastSuccessAt": Date(), "lastFinishedAt": Date(), "lastError": "", "reportsSaved": reportsSaved, "rowsSaved": rowsSaved, "lease_until": Date.distantPast, "next_run_at": Date().addingTimeInterval(300)] as Document]).get()
            try Self.checkWrite(finished)
            guard finished.updatableCount == 1 else { throw GA4Error.leaseLost }
            app.logger.info("GA4 import complete: \(reportsSaved) reports, \(rowsSaved) rows saved to analytics_snapshots")
        } catch {
            let code = (error as? GA4Error)?.safeCode ?? (error is CancellationError ? "cancelled" : "network_or_database_error")
            app.logger.error("GA4 import failed: \(code). Website remains available; previous complete reports retained.")
            if acquired, let database = try? mongo(app) {
                _ = try? await database["analytics_sync_state"].updateOne(where: ["_id": configuration.key, "owner": owner], to: ["$set": ["state": "failed", "lastFinishedAt": Date(), "lastError": code, "reportsSaved": reportsSaved, "rowsSaved": rowsSaved, "lease_until": Date.distantPast, "next_run_at": Date().addingTimeInterval(300)] as Document]).get()
            }
        }
    }

    static func checkWrite(_ reply: UpdateReply, allowDuplicate: Bool = false) throws {
        let errors = reply.writeErrors ?? []
        guard reply.ok == 1, reply.writeConcernError == nil,
              errors.isEmpty || (allowDuplicate && errors.allSatisfy { $0.code == 11000 }) else { throw reply }
    }

    func status(app: Application) async throws -> GA4SyncStatus {
        try await mongo(app)["analytics_sync_state"].findOne(["_id": configuration.key], as: GA4SyncStatus.self).get() ?? .init(enabled: true, state: "waiting_for_first_run")
    }

    func today(app: Application) async throws -> GA4Snapshot? {
        let id = "\(configuration.key):overview:\(GA4Configuration.day(Date()))"
        return try await mongo(app)["analytics_snapshots"].findOne(["_id": id], as: GA4Snapshot.self).get()
    }
}

struct GA4ServiceKey: StorageKey { typealias Value = GoogleAnalyticsService }
struct GA4ConfigurationErrorKey: StorageKey { typealias Value = Bool }

struct GoogleAnalyticsJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        await context.application.storage[GA4ServiceKey.self]?.run(app: context.application)
    }
}

final class GoogleAnalyticsLifecycle: LifecycleHandler, @unchecked Sendable {
    private var task: Task<Void, Never>?
    func didBoot(_ application: Application) throws {
        task = Task {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            await application.storage[GA4ServiceKey.self]?.run(app: application)
        }
    }
    func shutdown(_ application: Application) { task?.cancel() }
}

func configureGoogleAnalytics(_ app: Application) {
    do {
        guard let config = try GA4Configuration.load() else {
            app.logger.info("GA4 importer disabled; set GA4_ENABLED=true and GA4_SERVICE_ACCOUNT_JSON to enable")
            return
        }
        app.storage[GA4ServiceKey.self] = try GoogleAnalyticsService(configuration: config)
        app.queues.schedule(GoogleAnalyticsJob()).hourly().at(5)
        app.lifecycle.use(GoogleAnalyticsLifecycle())
        app.logger.info("GA4 importer configured: property \(config.propertyID), stream \(config.streamID); startup + hourly")
    } catch {
        app.storage[GA4ConfigurationErrorKey.self] = true
        app.logger.error("GA4 importer disabled: invalid GA4_SERVICE_ACCOUNT_JSON or numeric IDs. Backend startup continues.")
    }
}

extension AdminController {
    func setupAnalyticsRoutes(on routes: RoutesBuilder) {
        routes.get("analytics", "realtime") { req async throws -> Response in
            guard let service = req.application.storage[GA4ServiceKey.self] else {
                throw Abort(.serviceUnavailable, reason: "Analytics ist im Backend nicht konfiguriert.")
            }
            do {
                let payload = try await service.realtime(client: req.client)
                let response = try await payload.encodeResponse(for: req)
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response
            } catch {
                let code = (error as? GA4Error)?.safeCode ?? "network_error"
                req.logger.warning("GA4 realtime failed: \(code)")
                throw Abort(.badGateway, reason: "Live-Daten nicht verfügbar (\(code)).")
            }
        }
        routes.get("analytics", "dashboard") { req async throws -> Response in
            guard let service = req.application.storage[GA4ServiceKey.self] else {
                throw Abort(.serviceUnavailable, reason: "Analytics ist nicht konfiguriert. GA4_ENABLED und Zugangsdaten im Backend prüfen.")
            }
            do {
                let payload = try await service.dashboard(app: req.application, preset: req.query[String.self, at: "range"] ?? "7d", from: req.query[String.self, at: "from"], to: req.query[String.self, at: "to"])
                let response = try await payload.encodeResponse(for: req)
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response
            } catch let error as Abort { throw error }
            catch {
                let code = (error as? GA4Error)?.safeCode ?? "network_or_database_error"
                req.logger.warning("GA4 dashboard failed: \(code)")
                throw Abort(.badGateway, reason: "Analytics konnte nicht geladen werden (\(code)).")
            }
        }
        routes.get("analytics", "status") { req async throws -> GA4SyncStatus in
            guard let service = req.application.storage[GA4ServiceKey.self] else {
                return .init(enabled: false, state: req.application.storage[GA4ConfigurationErrorKey.self] == true ? "invalid_configuration" : "disabled")
            }
            return try await service.status(app: req.application)
        }
        routes.get("analytics", "today") { req async throws -> GA4Snapshot in
            guard let service = req.application.storage[GA4ServiceKey.self] else { throw Abort(.serviceUnavailable, reason: "GA4 importer is disabled") }
            guard let snapshot = try await service.today(app: req.application) else { throw Abort(.notFound, reason: "No analytics snapshot yet") }
            return snapshot
        }
    }
}
