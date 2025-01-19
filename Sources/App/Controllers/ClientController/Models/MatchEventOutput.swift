import Vapor
import Fluent

struct MatchEventOutput: Content, Codable {
    var id: UUID?
    var type: MatchEventType
    var minute: Int
    var name: String?
    var image: String?
    var number: String?
    var assign: MatchAssignment?
    var ownGoal: Bool?

    // Player info from the event
    var playerID: UUID?
    var playerName: String?
    var playerNumber: Int?
    var playerImage: String?
    var playerSid: String?
}
