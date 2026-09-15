import Foundation
import Vapor
import MongoKitten

/// One range definition drives all cards, charts and tables. End is exclusive.
struct GA4DashboardRange: Content {
    let preset: String
    let start: String
    let end: String
    let timeZone: String
    let granularity: String
    let provisional: Bool
    let startDate: String
    let endDate: String
    let startMinute: String
    let endMinute: String

    static let earliest = "2015-08-14"
    static func resolve(preset: String, from: String?, to: String?, now: Date = Date(), zone: TimeZone) throws -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func format(_ date: Date, _ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        func parse(_ value: String) throws -> Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard value.count == 10, let date = formatter.date(from: value), format(date, "yyyy-MM-dd") == value else {
                throw Abort(.badRequest, reason: "Ungültiges Datum (YYYY-MM-DD erforderlich).")
            }
            return date
        }
        let minuteNow = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        var end = minuteNow
        let start: Date
        switch preset {
        case "1h": start = end.addingTimeInterval(-3600)
        case "3h": start = end.addingTimeInterval(-10800)
        case "1d": start = end.addingTimeInterval(-86400)
        case "3d": start = calendar.date(byAdding: .day, value: -3, to: end)!
        case "7d": start = calendar.date(byAdding: .day, value: -7, to: end)!
        case "1m": start = calendar.date(byAdding: .month, value: -1, to: end)!
        case "3m": start = calendar.date(byAdding: .month, value: -3, to: end)!
        case "1y": start = calendar.date(byAdding: .year, value: -1, to: end)!
        case "all": start = try parse(earliest)
        case "custom":
            guard let from = from, let to = to else { throw Abort(.badRequest, reason: "Start- und Enddatum fehlen.") }
            start = try parse(from)
            let lastDay = try parse(to)
            guard from >= earliest, lastDay >= start, lastDay <= calendar.startOfDay(for: now) else {
                throw Abort(.badRequest, reason: "Zeitraum ungültig oder in der Zukunft.")
            }
            end = min(calendar.date(byAdding: .day, value: 1, to: lastDay)!, minuteNow)
        default: throw Abort(.badRequest, reason: "Unbekannter Zeitraum.")
        }
        guard start < end else { throw Abort(.badRequest, reason: "Zeitraum enthält noch keine vollständige Minute.") }
        let seconds = end.timeIntervalSince(start)
        let grain = seconds <= 10800 ? "dateHourMinute" : seconds <= 86400 * 3 ? "dateHour" : seconds <= 86400 * 100 ? "date" : "yearMonth"
        let iso = ISO8601DateFormatter()
        return .init(preset: preset, start: iso.string(from: start), end: iso.string(from: end), timeZone: zone.identifier,
                     granularity: grain, provisional: end > now.addingTimeInterval(-72 * 3600), startDate: format(start, "yyyy-MM-dd"),
                     endDate: format(end.addingTimeInterval(-60), "yyyy-MM-dd"), startMinute: format(start, "yyyyMMddHHmm"), endMinute: format(end, "yyyyMMddHHmm"))
    }

    func request(configuration: GA4Configuration, report: GA4Report, limit: Int, chronological: Bool = false) throws -> Data {
        let filters: [[String: Any]] = [
            ["filter": ["fieldName": "streamId", "stringFilter": ["matchType": "EXACT", "value": configuration.streamID]]],
            ["filter": ["fieldName": "dateHourMinute", "numericFilter": ["operation": "GREATER_THAN_OR_EQUAL", "value": ["int64Value": startMinute]]]],
            ["filter": ["fieldName": "dateHourMinute", "numericFilter": ["operation": "LESS_THAN", "value": ["int64Value": endMinute]]]]
        ]
        let order: [[String: Any]] = report.dimensions.isEmpty ? [] : chronological
            ? [["dimension": ["dimensionName": report.dimensions[0]]]]
            : [["metric": ["metricName": report.metrics[0]], "desc": true]]
        return try JSONSerialization.data(withJSONObject: [
            "dateRanges": [["startDate": startDate, "endDate": endDate]],
            "dimensions": report.dimensions.map { ["name": $0] }, "metrics": report.metrics.map { ["name": $0] },
            "dimensionFilter": ["andGroup": ["expressions": filters]], "orderBys": order,
            "limit": limit, "returnPropertyQuota": true
        ])
    }
}

struct GA4Dashboard: Content {
    static let overview = GA4Report(name: "overview", dimensions: [], metrics: ["totalUsers", "activeUsers", "newUsers", "sessions", "engagedSessions", "screenPageViews", "userEngagementDuration", "eventCount", "keyEvents"])
    struct Report: Content {
        let rows: [GA4Snapshot.Row]
        let rowCount: Int
        let limited: Bool
        let thresholded: Bool
        let sampled: Bool
        let dataLoss: Bool
    }
    let schemaVersion: Int
    let propertyID: String
    let streamID: String
    let range: GA4DashboardRange
    let fetchedAt: String
    let metrics: [String: Double]
    let reports: [String: Report]
    let cached: Bool

    static func metrics(_ values: [String: String]) -> [String: Double] {
        var result = values.reduce(into: [String: Double]()) { result, entry in
            if let value = Double(entry.value), value.isFinite { result[entry.key] = value }
        }
        // Totals are queried for the whole selected range, never summed from daily unique users.
        func ratio(_ output: String, _ numerator: String, _ denominator: String) {
            if let n = result[numerator], let d = result[denominator], d > 0 { result[output] = n / d }
        }
        ratio("sessionsPerUser", "sessions", "totalUsers")
        ratio("viewsPerSession", "screenPageViews", "sessions")
        ratio("engagementSecondsPerSession", "userEngagementDuration", "sessions")
        ratio("engagementRate", "engagedSessions", "sessions")
        if let rate = result["engagementRate"] { result["bounceRate"] = 1 - rate }
        return result
    }
    func fromCache() -> Self {
        .init(schemaVersion: schemaVersion, propertyID: propertyID, streamID: streamID, range: range, fetchedAt: fetchedAt, metrics: metrics, reports: reports, cached: true)
    }
}

struct GA4DashboardCache: Codable {
    let _id: String
    let savedAt: Date
    let payload: GA4Dashboard
    var requestedFrom: String?
    var requestedTo: String?
}

extension GoogleAnalyticsService {
    /// Read the actual property timezone; do not assume the server or browser timezone.
    func dashboardZone(client: Client) async throws -> TimeZone {
        if let zone = dashboardTimeZone { return zone }
        let probe = try await fetchPage(client: client, report: GA4Report.all[0], day: "yesterday", offset: 0)
        guard let name = probe.metadata?.timeZone, let zone = TimeZone(identifier: name) else { throw GA4Error.invalidResponse }
        dashboardTimeZone = zone
        return zone
    }

    func makeDashboard(client: Client, range: GA4DashboardRange) async throws -> GA4Dashboard {
        let specs: [GA4Report] = [
            GA4Dashboard.overview,
            .init(name: "visitors", dimensions: ["newVsReturning"], metrics: ["totalUsers"]),
            .init(name: "trend", dimensions: [range.granularity], metrics: ["activeUsers", "sessions", "screenPageViews"]),
            .init(name: "pages", dimensions: ["pagePath"], metrics: ["screenPageViews", "totalUsers", "userEngagementDuration"]),
            .init(name: "landing_pages", dimensions: ["landingPage"], metrics: ["sessions", "totalUsers", "engagedSessions"]),
            .init(name: "sources", dimensions: ["sessionSource", "sessionMedium"], metrics: ["sessions", "totalUsers"]),
            .init(name: "devices", dimensions: ["deviceCategory"], metrics: ["sessions", "totalUsers"]),
            .init(name: "countries", dimensions: ["country"], metrics: ["sessions", "totalUsers"]),
            .init(name: "events", dimensions: ["eventName"], metrics: ["eventCount", "totalUsers"])
        ]
        var reports: [String: GA4Dashboard.Report] = [:]
        var totals: [String: String] = [:]
        for report in specs {
            let limit = report.name == "trend" ? 500 : report.name == "overview" ? 1 : 20
            let body = try range.request(configuration: configuration, report: report, limit: limit, chronological: report.name == "trend")
            let response = try await fetchReport(client: client, report: report, body: body)
            guard response.metadata?.timeZone == range.timeZone else { dashboardTimeZone = nil; throw GA4Error.invalidResponse }
            var rows: [GA4Snapshot.Row] = []
            for row in response.rows ?? [] {
                guard (row.dimensionValues ?? []).count == report.dimensions.count, row.metricValues.count == report.metrics.count else { throw GA4Error.invalidResponse }
                rows.append(.init(dimensions: Dictionary(uniqueKeysWithValues: zip(report.dimensions, (row.dimensionValues ?? []).map(\.value))), metrics: Dictionary(uniqueKeysWithValues: zip(report.metrics, row.metricValues.map(\.value)))))
            }
            if report.name == "overview" {
                totals = rows.first?.metrics ?? Dictionary(uniqueKeysWithValues: report.metrics.map { ($0, "0") })
            }
            if report.name == "visitors" { totals["returningUsers"] = rows.first(where: { $0.dimensions["newVsReturning"] == "returning" })?.metrics["totalUsers"] ?? "0" }
            let count = response.rowCount ?? rows.count
            if report.name == "trend", count > limit { throw GA4Error.oversizedReport }
            reports[report.name] = .init(rows: rows, rowCount: count, limited: count > rows.count,
                thresholded: response.metadata?.subjectToThresholding == true, sampled: !(response.metadata?.samplingMetadatas ?? []).isEmpty, dataLoss: response.metadata?.dataLossFromOtherRow == true)
        }
        return .init(schemaVersion: 1, propertyID: configuration.propertyID, streamID: configuration.streamID, range: range,
                     fetchedAt: ISO8601DateFormatter().string(from: Date()), metrics: GA4Dashboard.metrics(totals), reports: reports, cached: false)
    }

    func dashboard(app: Application, preset: String, from: String?, to: String?) async throws -> GA4Dashboard {
        guard [from, to].compactMap({ $0 }).allSatisfy({ $0.count <= 10 }), preset.count <= 10,
              preset == "custom" || (from == nil && to == nil) else { throw Abort(.badRequest, reason: "Ungültige Zeitraumparameter.") }
        // Structural validation first; exact future-date validation follows in the property timezone.
        _ = try GA4DashboardRange.resolve(preset: preset, from: from, to: to, now: Date().addingTimeInterval(24 * 3600), zone: TimeZone(secondsFromGMT: 0)!)
        let key = "\(configuration.key):dashboard:v1:\(preset):\(from ?? ""):\(to ?? "")"
        if let task = dashboardPending[key] { return try await task.value }
        guard dashboardPending.count < 3 else { throw Abort(.tooManyRequests, reason: "Analytics lädt bereits. Bitte kurz warten.") }
        let cacheKey = "\(configuration.key):dashboard:v1:\(preset)"
        let task = Task<GA4Dashboard, Error> {
            let database = try self.mongo(app)
            if let cached = try await database["analytics_dashboard_cache"].findOne(["_id": cacheKey], as: GA4DashboardCache.self).get(),
               cached.requestedFrom == from, cached.requestedTo == to, cached.savedAt > Date().addingTimeInterval(-300) { return cached.payload.fromCache() }
            let zone = try await self.dashboardZone(client: app.client)
            let range = try GA4DashboardRange.resolve(preset: preset, from: from, to: to, zone: zone)
            let payload = try await self.makeDashboard(client: app.client, range: range)
            let write = try await database["analytics_dashboard_cache"].upsertEncoded(GA4DashboardCache(_id: cacheKey, savedAt: Date(), payload: payload, requestedFrom: from, requestedTo: to), where: ["_id": cacheKey]).get()
            try Self.checkWrite(write)
            return payload
        }
        dashboardPending[key] = task
        defer { dashboardPending.removeValue(forKey: key) }
        return try await task.value
    }
}
