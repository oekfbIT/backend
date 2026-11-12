import Vapor
import Fluent

struct PlayerDetailResponse: Codable, Content {
    let player: PublicPlayer
    var upcoming: [PublicSeasonMatches]?
    var news: [NewsItem]?
    var events: [AppModels.AppMatchEvent]?
}

