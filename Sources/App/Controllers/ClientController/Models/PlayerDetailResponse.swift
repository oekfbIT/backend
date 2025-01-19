import Vapor
import Fluent

struct PlayerDetailResponse: Codable, Content {
    let player: PublicPlayer
    var upcoming: [PublicMatchShort]?
    var news: [NewsItem]?
}
