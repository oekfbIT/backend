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
    struct Pair<T: Codable>: Codable {
        var home: T?; var away: T?
        mutating func swap() { (home, away) = (away, home) }
    }
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

    /// Swap home/away everywhere (used when the backend decides Veo's sides the other way round).
    mutating func flipSides() {
        let flip: (String?) -> String? = { $0 == "home" ? "away" : ($0 == "away" ? "home" : $0) }
        for i in shots.indices { shots[i].team = flip(shots[i].team) }
        for i in players.indices { players[i].team = flip(players[i].team) }
        if heatmap != nil {
            for i in heatmap!.teams.indices { heatmap!.teams[i].team = flip(heatmap!.teams[i].team) ?? heatmap!.teams[i].team }
            for i in heatmap!.players.indices { heatmap!.players[i].team = flip(heatmap!.players[i].team) ?? heatmap!.players[i].team }
        }
        for i in periods.indices {
            periods[i].possessionSeconds?.swap(); periods[i].passesCompleted?.swap(); periods[i].possessionWon?.swap()
            periods[i].passLocations?.swap(); periods[i].passGrid?.swap(); periods[i].possessionThirds?.swap()
            periods[i].possessionGrid?.swap(); periods[i].passStrings?.swap()
        }
    }

    var shots: [Shot]
    var periods: [Period]
    var heatmap: Heatmap?
    var players: [Physical]
    var trackingFrames: Int?
}
