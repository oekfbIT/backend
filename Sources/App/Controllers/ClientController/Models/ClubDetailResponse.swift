import Vapor
import Fluent

//struct ClubDetailResponse: Codable, Content {
//    let club: PublicTeamFull
//    var upcoming: [PublicMatchShort]?
//    var news: [NewsItem]?
//}

struct ClubDetailResponse: Codable, Content {
    let club: PublicTeamFull
    var upcoming: [PublicSeasonMatches]?
    var news: [NewsItem]?
}

struct PublicSeasonMatches: Codable, Content {
    var leagueName: String
    var leagueID: UUID
    var seasonID: UUID
    var seasonName: String
    var primary: Bool
    var matches: [PublicMatchShort]
}
