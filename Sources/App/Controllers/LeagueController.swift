//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.

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
        route.post(":id", "createSeason", use: createSeason)
        
        // Add the new route to get league with seasons
        route.get(":id", "seasons", use: getLeagueWithSeasons)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func createSeason(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                return league.createSeason(db: req.db).map {
                    return .ok
                }
            }
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
    

    struct LeagueWithSeasons: Content {
        var league: League
        var seasons: [Season]
    }

}

extension League {
    func createSeason(db: Database) -> EventLoopFuture<Void> {
        guard let leagueID = self.id else {
            return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League ID is required"))
        }

        // Generate the season name based on the current year
        let currentYear = Calendar.current.component(.year, from: Date())
        let nextYear = currentYear + 1
        let seasonName = "\(currentYear)/\(nextYear)"

        // Create a new season
        let season = Season(name: seasonName, details: 0)
        season.$league.id = leagueID
        
        return season.save(on: db).flatMap {
            // Fetch all teams in the league
            self.$teams.query(on: db).all().flatMap { teams in
                guard teams.count > 1 else {
                    return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League must have more than one team"))
                }

                var matches: [Match] = []

                // Generate the round-robin schedule (each team plays each other twice)
                let teamCount = teams.count
                var gameDay = 1

                for round in 0..<(teamCount - 1) {
                    for matchIndex in 0..<(teamCount / 2) {
                        let homeTeamIndex = (round + matchIndex) % (teamCount - 1)
                        var awayTeamIndex = (teamCount - 1 - matchIndex + round) % (teamCount - 1)
                        if matchIndex == 0 {
                            awayTeamIndex = teamCount - 1
                        }

                        let homeTeam = teams[homeTeamIndex]
                        let awayTeam = teams[awayTeamIndex]

                        // Create match
                        let match = Match(
                            details: MatchDetails(gameday: gameDay, date: nil, stadium: nil),
                            homeTeamId: homeTeam.id!,
                            awayTeamId: awayTeam.id!,
                            score: Score(home: 0, away: 0),
                            status: .pending
                        )
                        match.$season.id = season.id!
                        
                        matches.append(match)

                        // Swap home and away for the second leg
                        let reverseMatch = Match(
                            details: MatchDetails(gameday: gameDay + (teamCount / 2), date: nil, stadium: nil),
                            homeTeamId: awayTeam.id!,
                            awayTeamId: homeTeam.id!,
                            score: Score(home: 0, away: 0),
                            status: .pending
                        )
                        reverseMatch.$season.id = season.id!
                        
                        matches.append(reverseMatch)
                    }
                    gameDay += 1
                }

                // Save all matches to the database
                return matches.create(on: db)
            }
        }
    }
}


