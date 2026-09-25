import Vapor
import Fluent

enum PublicHomepageAccess {
    static func allows(code: String?, visibility: Bool?) -> Bool {
        visibility == true || code == "HME"
    }
}

// MARK: - Helper Fetch Methods (DB Calls)
extension ClientController {
    func fetchLeagueByCode(_ code: String, db: Database) -> EventLoopFuture<League> {
        League.query(on: db)
            .filter(\.$code == code)
            .filter(\.$visibility == true)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
    }

    /// The hidden HME record stores global landing-page content and is not a
    /// selectable competition. Permit that one record for the allowlisted
    /// homepage DTO without making any other hidden league publicly readable.
    func fetchHomepageLeagueByCode(_ code: String, db: Database) -> EventLoopFuture<League> {
        League.query(on: db)
            .filter(\.$code == code)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMapThrowing { league in
                guard PublicHomepageAccess.allows(code: league.code, visibility: league.visibility) else {
                    throw Abort(.notFound, reason: "League not found")
                }
                return league
            }
    }

    func fetchTeams(for league: League, db: Database) -> EventLoopFuture<[Team]> {
        league.$teams.query(on: db)
            .with(\.$players)
            .all()
    }

    func fetchLeagueNews(league: League, code: String, db: Database) -> EventLoopFuture<[NewsItem]> {
        NewsItem.query(on: db)
            .group(.or) { group in
                group.filter(\NewsItem.$tag == code)
                group.filter(\NewsItem.$tag == "Alle")
            }
            .sort(\.$created, .descending)
            .all()
    }

    func fetchSeasons(for league: League, db: Database) -> EventLoopFuture<[Season]> {
        league.$seasons.query(on: db)
            .with(\.$matches) { match in
                match.with(\.$homeTeam)
                     .with(\.$awayTeam)
            }
            .all()
    }

    func fetchTeam(byID teamID: UUID, db: Database) -> EventLoopFuture<Team> {
        Team.find(teamID, on: db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))
    }

    func fetchLeagueForTeam(_ team: Team, db: Database) -> EventLoopFuture<League?> {
        team.$league.get(on: db)
    }

    func fetchPlayers(for team: Team, db: Database) -> EventLoopFuture<[Player]> {
        team.$players.query(on: db).all()
    }

    func fetchAllPlayerStats(_ players: [Player], db: Database) -> EventLoopFuture<[MiniPlayer]> {
        let result = players.map { player in
                MiniPlayer(
                    id: player.id,
                    sid: player.sid,
                    image: player.image,
                    name: player.name,
                    number: player.number,
                    nationality: player.nationality,
                    position: player.position,
                    eligibility: player.eligibility,
                    status: player.status,
                    isCaptain: player.isCaptain
                )
        }
        return db.eventLoop.makeSucceededFuture(result)
    }

    func fetchTeamAndLeagueNews(teamName: String, leagueCode: String?, db: Database) -> EventLoopFuture<[NewsItem]> {
        let teamNewsFuture = fetchRelatedNewsItems(term: leagueCode ?? "", db: db)
        let leagueNewsFuture = (leagueCode ?? "").isEmpty ? db.eventLoop.future([]) : fetchRelatedNewsItems(term: leagueCode!, db: db)
        return teamNewsFuture.and(leagueNewsFuture).map { teamNews, leagueNews in
            teamNews + leagueNews
        }
    }

    func fetchRelatedNewsItems(term: String, db: Database) -> EventLoopFuture<[NewsItem]> {
        NewsItem.query(on: db)
            .group(.or) { group in
                group.filter(\NewsItem.$tag == term)
                group.filter(\NewsItem.$tag == "Alle")
            }
            .sort(\.$created, .descending)
            .all()
    }
}
