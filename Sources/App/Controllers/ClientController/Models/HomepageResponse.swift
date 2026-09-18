import Vapor
import Fluent

struct HomepageResponse: Codable, Content {
    var data: HomepageData?
    var teams: [PublicTeamShort]?
    var news: [NewsItem]?
    var upcoming: [PublicMatchShort]?
    let league: PublicLeagueOverview?
}

struct PublicSponsor: Codable, Content {
    let id: UUID?
    let name: String?
    let link: String?
    let logo: String?
    let footerLogo: String?
    let type: SponsorType?
    let position: Int?

    init(_ sponsor: Sponsor) {
        id = sponsor.id
        name = sponsor.name
        link = sponsor.link
        logo = sponsor.logo
        footerLogo = sponsor.footerLogo
        type = sponsor.type
        position = sponsor.position
    }
}
