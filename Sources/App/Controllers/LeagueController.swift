import Vapor
import Fluent

final class LeagueController: RouteCollection {
    let repository: StandardControllerRepository<League>

    init(path: String) {
        self.repository = StandardControllerRepository<League>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        
        // Add the new route for creating a season
        route.post(":id", "createSeason", ":number", use: createSeason)

        // Add the new route to get league with seasons
        route.get(":id", "seasons", use: getLeagueWithSeasons)
        route.get("code", ":code", use: getLeaguebyCode)
        route.get(":id", "teamCount", use: getNumberOfTeams)

        // Add the new route to get leagues by state
        route.get("state", ":state", use: getLeaguesForState)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func createSeason(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let leagueID = req.parameters.get("id", as: UUID.self),
        let numberOfRounds = req.parameters.get("number", as: Int.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing parameters"))
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                return league.createSeason(db: req.db, numberOfRounds: numberOfRounds).map {
                    return .ok
                }
            }
    }
    
    func getLeaguebyCode(req: Request) -> EventLoopFuture<League> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league Code"))
        }

        return League.query(on: req.db)
            .filter(\.$code == leagueCode)
            .with(\.$teams)
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
                return LeagueWithSeasons(league: league, seasons: league.seasons)
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

    struct LeagueWithSeasons: Content {
        var league: League
        var seasons: [Season]
    }

}

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

        // Save the season first
        return season.save(on: db).flatMap { _ in
            // Query all teams in the league
            self.$teams.query(on: db).all().flatMap { teamsArray in
                // Here, teamsArray is an array of Team objects
                
                guard teamsArray.count > 1 else {
                    return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League must have more than one team"))
                }

                var teams = teamsArray  // Now teams is correctly recognized as an array
                let isOddTeamCount = teams.count % 2 != 0

                // If odd number of teams, add a "bye" team
                if isOddTeamCount {
                    let byeTeam = Team(id: UUID(),
                                       sid: "", userId: nil, leagueId: nil, leagueCode: nil, points: 0, coverimg: "", logo: "", teamName: "Bye", foundationYear: "", membershipSince: "", averageAge: "", coach: nil, captain: "", trikot: Trikot(home: "", away: ""), balance: 0.0, referCode: "", usremail: "", usrpass: "", usrtel: "")
                    teams.append(byeTeam)
                }

                let teamCount = teams.count
                var matches: [Match] = []
                let totalGameDays = (teamCount - 1) * numberOfRounds
                var gameDay = 1
                var homeAwaySwitch = false

                for round in 0..<numberOfRounds {
                    for roundIndex in 0..<(teamCount - 1) {
                        for matchIndex in 0..<(teamCount / 2) {
                            let homeTeamIndex = (roundIndex + matchIndex) % (teamCount - 1)
                            var awayTeamIndex = (teamCount - 1 - matchIndex + roundIndex) % (teamCount - 1)

                            if matchIndex == 0 {
                                awayTeamIndex = teamCount - 1
                            }

                            var homeTeam = teams[homeTeamIndex]
                            var awayTeam = teams[awayTeamIndex]

                            // Skip creating a match if either team is the "bye" team
                            if homeTeam.teamName == "Bye" || awayTeam.teamName == "Bye" {
                                continue
                            }

                            if homeAwaySwitch {
                                swap(&homeTeam, &awayTeam)
                            }

                            let match = Match(
                                details: MatchDetails(gameday: gameDay, date: nil, stadium: nil, location: "Nicht Zugeornet"),
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

                // Validate the number of matches
//                let expectedMatches = isOddTeamCount ? (teamCount - 1) * numberOfRounds : (teamCount / 2) * (teamCount - 1) * numberOfRounds
//                guard matches.count == expectedMatches else {
//                    return db.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Incorrect match calculation"))
//                }

                // Save all matches to the database
                return matches.create(on: db).transform(to: ())
            }
        }
    }
}
