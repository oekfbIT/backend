import Vapor
import Fluent

final class LeagueController: RouteCollection {
    let repository: StandardControllerRepository<League>
    
    init(path: String) {
        self.repository = StandardControllerRepository<League>(path: path)
    }
    
    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)
        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.get(":id", "tabelle", use: getLeagueTable)
        route.delete(":id", use: repository.deleteID)
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        route.post(":id", "createSeason", ":number", use: createSeason)
        route.get(":id", "seasons", use: getLeagueWithSeasons)
        route.get("code", ":code", use: getLeaguebyCode)
        route.get(":id", "teamCount", use: getNumberOfTeams)
        route.get("state", ":state", use: getLeaguesForState)
        
        route.get(":id", "goalLeaderBoard", use: getGoalLeaderBoard)
        route.get(":id", "redCardLeaderBoard", use: getRedCardLeaderBoard)
        route.get(":id", "yellowCardLeaderBoard", use: getYellowCardLeaderBoard)
    }
    
    func getLeagueTable(req: Request) -> EventLoopFuture<[TableItem]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                league.$teams.query(on: req.db).all().flatMap { teams in
                    let teamStatsFutures = teams.map { team in
                        self.getTeamStats(teamID: team.id!, db: req.db).map { stats in (team, stats) }
                    }

                    return req.eventLoop.flatten(teamStatsFutures).map { teamStatsPairs in
                        var tableItems: [TableItem] = []
                        
                        for (team, stats) in teamStatsPairs {
                            let tableItem = TableItem(
                                image: team.logo,
                                name: team.teamName,
                                points: team.points,
                                id: team.id!,
                                goals: stats.totalScored,
                                ranking: 0,
                                wins: stats.wins,
                                draws: stats.draws,
                                losses: stats.losses,
                                scored: stats.totalScored,
                                against: stats.totalAgainst,
                                difference: stats.goalDifference
                            )
                            tableItems.append(tableItem)
                        }
                        
                        tableItems.sort {
                            if $0.points == $1.points {
                                return $0.difference > $1.difference
                            }
                            return $0.points > $1.points
                        }

                        for i in 0..<tableItems.count {
                            tableItems[i].ranking = i + 1
                        }
                        
                        return tableItems
                    }
                }
            }
    }

    // Similar to HomepageController, we keep stats logic concise
    func getTeamStats(teamID: UUID, db: Database) -> EventLoopFuture<TeamStats> {
        let validStatuses: [GameStatus] = [.completed, .abbgebrochen, .submitted, .cancelled, .done]

        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                group.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status ~~ validStatuses)
            .with(\.$events)
            .all()
            .map { matches in
                var stats = TeamStats(wins: 0, draws: 0, losses: 0, totalScored: 0, totalAgainst: 0, goalDifference: 0, totalPoints: 0, totalYellowCards: 0, totalRedCards: 0)
                
                for match in matches {
                    let isHome = match.$homeTeam.id == teamID
                    let scored = isHome ? match.score.home : match.score.away
                    let against = isHome ? match.score.away : match.score.home

                    stats.totalScored += scored
                    stats.totalAgainst += against

                    if scored > against {
                        stats.wins += 1
                        stats.totalPoints += 3
                    } else if scored == against {
                        stats.draws += 1
                        stats.totalPoints += 1
                    } else {
                        stats.losses += 1
                    }

                    for event in match.events {
                        if let assign = event.assign {
                            if (isHome && assign == .home) || (!isHome && assign == .away) {
                                switch event.type {
                                case .yellowCard:
                                    stats.totalYellowCards += 1
                                case .redCard:
                                    stats.totalRedCards += 1
                                default:
                                    break
                                }
                            }
                        }
                    }
                }

                stats.goalDifference = stats.totalScored - stats.totalAgainst
                return stats
            }
    }

    func createSeason(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let leagueID = req.parameters.get("id", as: UUID.self),
              let numberOfRounds = req.parameters.get("number", as: Int.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing parameters"))
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                league.createSeason(db: req.db, numberOfRounds: numberOfRounds).map {
                    return .ok
                }
            }
    }

    func getLeaguebyCode(req: Request) -> EventLoopFuture<League> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league code"))
        }

        return League.query(on: req.db)
            .filter(\.$code == leagueCode)
            .with(\.$teams)
            .with(\.$seasons)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
    }

    func getLeagueWithSeasons(req: Request) -> EventLoopFuture<LeagueWithSeasons> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$seasons)
            .with(\.$teams)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .map { league in
                LeagueWithSeasons(league: league, seasons: league.seasons)
            }
    }

    func getNumberOfTeams(req: Request) -> EventLoopFuture<Int> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                league.$teams.query(on: req.db).count()
            }
    }

    func getLeaguesForState(req: Request) -> EventLoopFuture<[League]> {
        guard let state = req.parameters.get("state", as: Bundesland.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing state parameter"))
        }

        return League.query(on: req.db)
            .filter(\.$state == state)
            .all()
    }

    // MARK: - Leaderboards

    func getGoalLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .goal)
    }

    func getRedCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .redCard)
    }

    func getYellowCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .yellowCard)
    }

    private func getLeaderBoard(req: Request, eventType: MatchEventType) -> EventLoopFuture<[LeaderBoard]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return Team.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$players)
            .all()
            .flatMap { teams in
                let playerIDs = teams.flatMap { $0.players.compactMap { $0.id } }

                return MatchEvent.query(on: req.db)
                    .filter(\.$player.$id ~~ playerIDs)
                    .filter(\.$type == eventType)
                    .all()
                    .map { events in
                        self.mapEventsToLeaderBoard(events)
                    }
            }
    }

    private func mapEventsToLeaderBoard(_ events: [MatchEvent]) -> [LeaderBoard] {
        // MARK: - Aggregation Dictionary
        // Using a dictionary keyed by player ID to count how many times a particular event occurred for that player.
        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, count: Int)] = [:]

        // MARK: - Counting Events
        // Iterate through each event and aggregate the counts based on the player ID.
        for event in events {
            let playerId = event.$player.id
            let playerInfo = (event.name, event.image, event.number)

            // If the player is already in the dictionary, increment their count; otherwise, start at 1.
            if let existingData = playerEventCounts[playerId] {
                playerEventCounts[playerId] = (existingData.name, existingData.image, existingData.number, existingData.count + 1)
            } else {
                playerEventCounts[playerId] = (playerInfo.0, playerInfo.1, playerInfo.2, 1)
            }
        }

        // MARK: - Building the Leaderboard Array
        // Convert the dictionary into an array of LeaderBoard objects.
        let leaderboard = playerEventCounts.map { (_, playerData) in
            LeaderBoard(
                name: playerData.name,
                image: playerData.image,
                number: playerData.number,
                count: playerData.count.asDouble()
            )
        }
        // Sort the leaderboard by event count in descending order.
        .sorted { $0.count ?? 0 > $1.count ?? 0 }

        // MARK: - Return the Final Leaderboard
        return leaderboard
    }

}

// MARK: - Supporting Models

struct LeagueWithSeasons: Content {
    var league: League
    var seasons: [Season]
}

struct TableItem: Codable, Content {
    var image: String
    var name: String
    var points: Int
    var id: UUID
    var goals: Int
    var ranking: Int
    var wins: Int
    var draws: Int
    var losses: Int
    var scored: Int
    var against: Int
    var difference: Int
}

struct LeaderBoard: Codable, Content {
    let name: String?
    let image: String?
    let number: String?
    let count: Double?
}

struct TeamStats: Content, Codable {
    var wins: Int
    var draws: Int
    var losses: Int
    var totalScored: Int
    var totalAgainst: Int
    var goalDifference: Int
    var totalPoints: Int
    var totalYellowCards: Int
    var totalRedCards: Int
}

extension Int {
    func asDouble() -> Double {
        Double(self)
    }
}
