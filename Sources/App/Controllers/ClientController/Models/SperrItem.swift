import Vapor
import Fluent

struct SperrItem: Codable, Content {
    let playerName: String?
    let playerImage: String?
    let playerSid: String?
    let playerid: UUID?
    let playerEligibility: String?
    let teamName: String?
    let teamImage: String?
    let teamSid: String?
    let teamid: UUID?
    let blockdate: Date?
}
