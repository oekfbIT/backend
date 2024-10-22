import Vapor
import Fluent

struct LeaderBoard: Codable, Content {
    var name: String?
    var image: String?
    var number: String?
    var count: Int // The total number of
}

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
        
        route.get(":id", "goalLeaderBoard", use: getGoalLeaderBoard) // LeagueID
        route.get(":id", "redCardLeaderBoard", use: getRedCardLeaderBoard) // LeagueID
        route.get(":id", "yellowCardLeaderBoard", use: getYellowCardLeaderBoard)// LeagueID
    }
    
    // MARK: - Core CRUD Handlers
    func getLeagueTable(req: Request) -> EventLoopFuture<[TableItem]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                // Fetch all teams in the league
                league.$teams.query(on: req.db).all().flatMap { teams in
                    // Create an array of futures to fetch match stats for each team
                    let teamStatsFutures = teams.map { team in
                        self.getTeamStats(teamID: team.id!, db: req.db).map { stats in
                            return (team, stats)
                        }
                    }
                    
                    // Flatten the array of futures into a single future
                    return req.eventLoop.flatten(teamStatsFutures).map { teamStatsPairs in
                        // Create table items with points, goals, wins, draws, losses, etc.
                        var tableItems: [TableItem] = []
                        
                        for (team, stats) in teamStatsPairs {
                            let tableItem = TableItem(
                                image: team.logo,
                                name: team.teamName,
                                points: team.points,
                                id: team.id!,
                                goals: stats.totalScored,
                                ranking: 0,  // Ranking will be assigned after sorting
                                wins: stats.wins,
                                draws: stats.draws,
                                losses: stats.losses,
                                scored: stats.totalScored,
                                against: stats.totalAgainst,
                                difference: stats.goalDifference
                            )
                            tableItems.append(tableItem)
                        }
                        
                        // Sort teams by points, then by goal difference
                        tableItems.sort {
                            if $0.points == $1.points {
                                return $0.difference > $1.difference
                            }
                            return $0.points > $1.points
                        }
                        
                        // Assign rankings
                        for i in 0..<tableItems.count {
                            tableItems[i].ranking = i + 1
                        }
                        
                        return tableItems
                    }
                }
            }
    }
    
    // Helper to get team stats
    func getTeamStats(teamID: UUID, db: Database) -> EventLoopFuture<TeamStats> {
        let validStatuses: [GameStatus] = [ .completed, .abbgebrochen, .submitted, .cancelled, .done]
        
        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                    .filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status ~~ validStatuses) // Filter matches by valid statuses
            .all()
            .map { matches in
                var wins = 0
                var draws = 0
                var losses = 0
                var totalScored = 0
                var totalAgainst = 0
                var totalPoints = 0
                
                for match in matches {
                    let isHome = match.$homeTeam.id == teamID
                    let scored = isHome ? match.score.home : match.score.away
                    let against = isHome ? match.score.away : match.score.home
                    
                    totalScored += scored
                    totalAgainst += against
                    
                    if scored > against {
                        wins += 1
                        totalPoints += 3
                    } else if scored == against {
                        draws += 1
                        totalPoints += 1
                    } else {
                        losses += 1
                    }
                }
                
                let goalDifference = totalScored - totalAgainst
                
                return TeamStats(
                    wins: wins,
                    draws: draws,
                    losses: losses,
                    totalScored: totalScored,
                    totalAgainst: totalAgainst,
                    goalDifference: goalDifference,
                    totalPoints: totalPoints
                )
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
    
    // MARK: - Leaderboard Handlers

    func getGoalLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .goal)
    }

    func getRedCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .redCard)
    }

    func getYellowCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .yellowCard)
    }

    // Generalized function for all leaderboards
    private func getLeaderBoard(req: Request, eventType: MatchEventType) -> EventLoopFuture<[LeaderBoard]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        // Fetch teams and their players from the specified league
        return Team.query(on: req.db)
            .filter(\.$league.$id == leagueID) // Filter by the provided league ID
            .with(\.$players) // Load related players
            .all()
            .flatMap { teams in
                // Collect all player IDs from the league's teams
                let playerIDs = teams.flatMap { $0.players.compactMap { $0.id } }

                // Fetch all match events for these players
                return MatchEvent.query(on: req.db)
                    .filter(\.$player.$id ~~ playerIDs) // Only include events for players from the league
                    .filter(\.$type == eventType) // Filter by event type (goal, red card, yellow card)
                    .all()
                    .flatMap { events in
                        // Create a dictionary to count events per player
                        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, count: Int)] = [:]

                        for event in events {
                            let playerId = event.$player.id
                            let playerInfo = (event.name, event.image, event.number)
                            
                            if let existingCount = playerEventCounts[playerId]?.count {
                                playerEventCounts[playerId]?.count = existingCount + 1
                            } else {
                                playerEventCounts[playerId] = (playerInfo.0, playerInfo.1, playerInfo.2, 1)
                            }
                        }

                        // Convert the dictionary into a sorted array of LeaderBoard items
                        let leaderboard = playerEventCounts.map { (playerId, playerData) in
                            LeaderBoard(
                                name: playerData.name,
                                image: playerData.image,
                                number: playerData.number,
                                count: playerData.count
                            )
                        }.sorted { $0.count > $1.count }

                        return req.eventLoop.makeSucceededFuture(leaderboard)
                    }
            }
    }

}

// MARK: - LeagueWithSeasons Struct

struct LeagueWithSeasons: Content {
    var league: League
    var seasons: [Season]
}

// MARK: - TableItem Struct

struct TeamStats: Codable {
    var wins: Int
    var draws: Int
    var losses: Int
    var totalScored: Int
    var totalAgainst: Int
    var goalDifference: Int
    var totalPoints: Int
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

// MARK: - League Extension to Handle Seasons

extension League {
    func createSeason(db: Database, numberOfRounds: Int) -> EventLoopFuture<Void> {
        guard let leagueID = self.id else {
            return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League ID is required"))
        }

        let currentYear = Calendar.current.component(.year, from: Date())
        let nextYear = currentYear + 1
        let seasonName = "\(currentYear)/\(nextYear)"
        let season = Season(name: seasonName, details: 0)
        season.$league.id = leagueID

        return season.save(on: db).flatMap {
            self.$teams.query(on: db).all().flatMap { teams in
                guard teams.count > 1 else {
                    return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League must have more than one team"))
                }

                var matches: [Match] = []
                let isOddTeamCount = teams.count % 2 != 0
                var teamsCopy = teams

                if isOddTeamCount {
                    let byeTeam = Team(id: UUID(), sid: "", userId: nil, leagueId: nil, leagueCode: nil, points: 0, coverimg: "", logo: "", teamName: "Bye", foundationYear: "", membershipSince: "", averageAge: "", coach: nil, captain: "", trikot: Trikot(home: "", away: ""), balance: 0.0, referCode: "", usremail: "", usrpass: "", usrtel: "")
                    teamsCopy.append(byeTeam)
                }

                var gameDay = 1
                let totalGameDays = (teamsCopy.count - 1) * numberOfRounds

                for round in 0..<numberOfRounds {
                    var homeAwaySwitch = false

                    for roundIndex in 0..<(teamsCopy.count - 1) {
                        for matchIndex in 0..<(teamsCopy.count / 2) {
                            let homeTeamIndex = (roundIndex + matchIndex) % (teamsCopy.count - 1)
                            var awayTeamIndex = (teamsCopy.count - 1 - matchIndex + roundIndex) % (teamsCopy.count - 1)

                            if matchIndex == 0 {
                                awayTeamIndex = teamsCopy.count - 1
                            }

                            var homeTeam = teamsCopy[homeTeamIndex]
                            var awayTeam = teamsCopy[awayTeamIndex]

                            if homeTeam.teamName == "Bye" || awayTeam.teamName == "Bye" {
                                continue
                            }

                            if homeAwaySwitch {
                                swap(&homeTeam, &awayTeam)
                            }

                            let match = Match(
                                details: MatchDetails(gameday: gameDay, date: nil, stadium: nil, location: "Nicht Zugeordnet"),
                                homeTeamId: homeTeam.id!,
                                awayTeamId: awayTeam.id!,
                                homeBlanket: Blankett(name: homeTeam.teamName, dress: homeTeam.trikot.home, logo: homeTeam.logo, players: [], coach: homeTeam.coach),
                                awayBlanket: Blankett(name: awayTeam.teamName, dress: awayTeam.trikot.away, logo: awayTeam.logo, players: [], coach: awayTeam.coach),
                                score: Score(home: 0, away: 0),
                                status: .pending
                            )

                            match.$season.id = season.id!
                            matches.append(match)
                        }
                        gameDay += 1
                        if gameDay > totalGameDays {
                            gameDay = 1
                        }
                    }

                    homeAwaySwitch.toggle()
                }

                return matches.create(on: db).transform(to: ())
            }
        }
    }
}
