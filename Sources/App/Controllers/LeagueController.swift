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
    }

    // MARK: - Core CRUD Handlers

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

    // MARK: - League Table Calculation

    func getTotalGoalsForTeam(teamID: UUID, db: Database) -> EventLoopFuture<Int> {
        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                     .filter(\.$awayTeam.$id == teamID)
            }
            .all()
            .map { matches in
                // Initialize total goals counter
                var totalGoals = 0
                
                // Loop through each match and sum the goals
                for match in matches {
                    if match.$homeTeam.id == teamID {
                        totalGoals += match.score.home
                    } else if match.$awayTeam.id == teamID {
                        totalGoals += match.score.away
                    }
                }
                
                // Return the total goals for this team
                return totalGoals
            }
    }

    func getLeagueTable(req: Request) -> EventLoopFuture<[TableItem]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                // Fetch all teams in the league
                league.$teams.query(on: req.db).all().flatMap { teams in
                    // Create an array of futures to fetch goals for each team
                    let teamGoalsFutures = teams.map { team in
                        self.getTotalGoalsForTeam(teamID: team.id!, db: req.db).map { totalGoals in
                            return (team, totalGoals)
                        }
                    }
                    
                    // Flatten the array of futures into a single future
                    return req.eventLoop.flatten(teamGoalsFutures).map { teamGoalsPairs in
                        // Create table items with points and goals
                        var tableItems: [TableItem] = []
                        
                        for (team, totalGoals) in teamGoalsPairs {
                            // Calculate points for the team
                            // In this case, assume team.points is already calculated elsewhere
                            let points = team.points  // Replace this with actual point calculation if needed
                            
                            let tableItem = TableItem(
                                image: team.logo,
                                name: team.teamName,
                                points: points,
                                id: team.id!,
                                goals: totalGoals,
                                ranking: 0  // Ranking will be assigned after sorting
                            )
                            tableItems.append(tableItem)
                        }

                        // Sort teams by points, then by goals
                        tableItems.sort {
                            if $0.points == $1.points {
                                return $0.goals > $1.goals
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

}

// MARK: - LeagueWithSeasons Struct

struct LeagueWithSeasons: Content {
    var league: League
    var seasons: [Season]
}

// MARK: - TableItem Struct

struct TableItem: Codable, Content {
    var image: String
    var name: String
    var points: Int
    var id: UUID
    var goals: Int
    var ranking: Int
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
