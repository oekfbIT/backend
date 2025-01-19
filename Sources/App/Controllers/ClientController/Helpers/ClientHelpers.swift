import Vapor
import Fluent

// MARK: - Helper Fetch Methods (DB Calls)
extension ClientController {
    func fetchLeagueByCode(_ code: String, db: Database) -> EventLoopFuture<League> {
        League.query(on: db)
            .filter(\.$code == code)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
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
        let futures = players.map { player in
            self.getPlayerStats(playerID: player.id!, db: db).map { stats in
                MiniPlayer(
                    id: player.id,
                    sid: player.sid,
                    image: player.image,
                    team_oeid: player.team_oeid,
                    name: player.name,
                    number: player.number,
                    birthday: player.birthday,
                    nationality: player.nationality,
                    position: player.position,
                    eligibility: player.eligibility,
                    registerDate: player.registerDate,
                    status: player.status,
                    isCaptain: player.isCaptain,
                    bank: player.bank
                )
            }
        }
        return db.eventLoop.flatten(futures)
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
            .all()
    }
}

