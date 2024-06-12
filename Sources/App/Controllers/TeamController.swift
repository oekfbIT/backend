//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class TeamController: RouteCollection {
    let repository: StandardControllerRepository<Team>

    init(path: String) {
        self.repository = StandardControllerRepository<Team>(path: path)
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
        
//        route.get(":oeid/players", use: getTeamWithPlayers) // Route to get a team with its players
        route.get("withPlayers", use: getAllTeamsWithPlayers) // Route to get all teams with their players

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    // Function to get a team with all its players
    func getTeamWithPlayers(req: Request) throws -> EventLoopFuture<Team> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$players)
            .first()
            .unwrap(or: Abort(.notFound))
    }

    // Function to get all teams with their players
    func getAllTeamsWithPlayers(req: Request) throws -> EventLoopFuture<[Team]> {
        return Team.query(on: req.db)
            .with(\.$players)
            .all()
    }

    
    // func getTeamWithPLayers, parameter: teamID
    // func getteamwithMatches, parameter: teamID
    // func getTeamInbox, parameter: teamID
    // func registerPlayer, parameter: player, teamID
    // func updatePlayerNumber, parameter: playerID
    // func registerCaptain, parameter: playerID, teamID
    // func registerTrainer, parameter: trainer, teamID
    // func getTeamBilling, parameter: teamID
    
    
}

extension Team: Mergeable {
    func merge(from other: Team) -> Team {
        var merged = self
        merged.id = other.id
        merged.points = other.points
        merged.logo = other.logo
        merged.teamName = other.teamName
        merged.foundationYear = other.foundationYear
        merged.membershipSince = other.membershipSince
        merged.averageAge = other.averageAge
        merged.coach = other.coach
        merged.captain = other.captain
        merged.trikot = other.trikot
        merged.balance = other.balance
        return merged
    }
}
