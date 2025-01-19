import Vapor
import Fluent

struct SperrItem: Codable, Content {
    let playerName: String?
    let playerImage: String?
    let playerSid: String?
    let teamName: String?
    let teamImage: String?
    let teamSid: String?
    let blockdate: Date?
}
