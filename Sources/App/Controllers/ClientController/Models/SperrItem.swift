import Vapor
import Fluent

struct SperrItem: Codable, Content {
    let playerName: String?
    let playerImage: String?
    let playerSid: String?
    let playerEligibility: String?
    let teamName: String?
    let teamImage: String?
    let teamSid: String?
    let teamID: UUID?
    let blockdate: Date?
}
