import Foundation
import Vapor

struct GA4Realtime: Content {
    let schemaVersion: Int
    let fetchedAt: String
    let activeUsers30: Double
    let activeUsers5: Double
    let pageViews30: Double
    let eventCount30: Double
    let minutes: [GA4Snapshot.Row]
    let events: [GA4Snapshot.Row]

    static func request(configuration: GA4Configuration, report: GA4Report, lastFive: Bool = false) throws -> Data {
        var filters: [[String: Any]] = [["filter": ["fieldName": "streamId", "stringFilter": ["matchType": "EXACT", "value": configuration.streamID]]]]
        if lastFive { filters.append(["filter": ["fieldName": "minutesAgo", "numericFilter": ["operation": "LESS_THAN_OR_EQUAL", "value": ["int64Value": "4"]]]]) }
        return try JSONSerialization.data(withJSONObject: [
            "dimensions": report.dimensions.map { ["name": $0] }, "metrics": report.metrics.map { ["name": $0] },
            "dimensionFilter": ["andGroup": ["expressions": filters]], "limit": report.name == "events" ? 5 : 30,
            "orderBys": report.name == "events" ? [["metric": ["metricName": "eventCount"], "desc": true]] : []
        ])
    }
}

extension GoogleAnalyticsService {
    func fetchRealtime(client: Client) async throws -> GA4Realtime {
        var results: [String: [GA4Snapshot.Row]] = [:]
        for report in [
            GA4Report(name: "totals", dimensions: [], metrics: ["activeUsers", "screenPageViews", "eventCount"]),
            GA4Report(name: "five", dimensions: [], metrics: ["activeUsers"]),
            GA4Report(name: "minutes", dimensions: ["minutesAgo"], metrics: ["activeUsers"]),
            GA4Report(name: "events", dimensions: ["eventName"], metrics: ["eventCount"])
        ] {
            let body = try GA4Realtime.request(configuration: configuration, report: report, lastFive: report.name == "five")
            let response = try await fetchReport(client: client, report: report, body: body, realtime: true)
            results[report.name] = try (response.rows ?? []).map { row in
                guard (row.dimensionValues ?? []).count == report.dimensions.count, row.metricValues.count == report.metrics.count else { throw GA4Error.invalidResponse }
                return .init(dimensions: Dictionary(uniqueKeysWithValues: zip(report.dimensions, (row.dimensionValues ?? []).map(\.value))), metrics: Dictionary(uniqueKeysWithValues: zip(report.metrics, row.metricValues.map(\.value))))
            }
        }
        func value(_ name: String, _ metric: String) -> Double {
            Double(results[name]?.first?.metrics[metric] ?? "0") ?? 0
        }
        return .init(schemaVersion: 1, fetchedAt: ISO8601DateFormatter().string(from: Date()), activeUsers30: value("totals", "activeUsers"), activeUsers5: value("five", "activeUsers"), pageViews30: value("totals", "screenPageViews"), eventCount30: value("totals", "eventCount"), minutes: results["minutes"] ?? [], events: results["events"] ?? [])
    }
    func realtime(client: Client) async throws -> GA4Realtime {
        if let cached = realtimeCache, cached.expires > Date() { return cached.payload }
        if let pending = realtimePending { return try await pending.value }
        let task = Task { try await self.fetchRealtime(client: client) }
        realtimePending = task
        defer { realtimePending = nil }
        let payload = try await task.value
        realtimeCache = (Date().addingTimeInterval(30), payload)
        return payload
    }
}
