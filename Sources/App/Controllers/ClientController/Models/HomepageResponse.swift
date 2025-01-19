import Vapor
import Fluent

struct HomepageResponse: Codable, Content {
    var data: HomepageData?
    var teams: [PublicTeamShort]?
    var news: [NewsItem]?
    var upcoming: [PublicMatchShort]?
    let league: League?
}
