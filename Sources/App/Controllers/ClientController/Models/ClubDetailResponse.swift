import Vapor
import Fluent

struct ClubDetailResponse: Codable, Content {
    let club: PublicTeamFull
    var upcoming: [PublicMatchShort]?
    var news: [NewsItem]?
}
