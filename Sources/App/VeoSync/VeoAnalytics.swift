import Foundation
import Vapor

/// Veo "Analytics" panel, oriented to home/away by the worker (see tools/veo-sync/src/analytics.mjs).
/// Property names are camelCase on purpose: the global JSON coders map them to/from snake_case.
struct VeoAnalytics: Codable {
    struct Shot: Codable {
        var veoId: String?
        var type: String            // goal | shot
        var team: String?           // home | away
        var period: Int?
        var videoSecond: Double
        var x: Double?              // 0…1 along the pitch, as filmed
        var y: Double?              // 0…1 across the pitch
        var jerseyNumber: Int?
        var outcome: Int?
    }
    struct Pair<T: Codable>: Codable { var home: T?; var away: T? }
    struct Thirds: Codable { var attacking: Int?; var middle: Int?; var defensive: Int? }
    struct Period: Codable {
        var period: Int
        var start: Double?
        var end: Double?
        var possessionSeconds: Pair<Int>?
        var passesCompleted: Pair<Int>?
        var possessionWon: Pair<Int>?
        var passLocations: Pair<[[Double]]>?
        var passGrid: Pair<[Int]>?          // 18-zone system
        var possessionThirds: Pair<Thirds>?
        var possessionGrid: Pair<[Int]>?    // 18-zone system
        var passStrings: Pair<[[Int]]>?     // [passes in a row, count]
    }
    struct HeatGrid: Codable { var team: String; var period: Int?; var jerseyNumber: Int?; var values: [Int] }
    struct Heatmap: Codable { var gridX: Int; var gridY: Int; var teams: [HeatGrid]; var players: [HeatGrid] }
    struct Physical: Codable {
        var jerseyNumber: Int
        var team: String?
        var distance: Double?
        var secondsPlayed: Double?
        var maxSpeed: Double?
        var averageSpeed: Double?
        var sprints: Int?
        var hsr: Double?
    }

    var shots: [Shot]
    var periods: [Period]
    var heatmap: Heatmap?
    var players: [Physical]
    var trackingFrames: Int?
}
