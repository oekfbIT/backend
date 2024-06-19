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
        
        route.get(":id", "players", use: getTeamWithPlayers) // Route to get a team with its players
        route.get("withPlayers", use: getAllTeamsWithPlayers) // Route to get all teams with their players
        
        route.get("search", ":value", use: searchByTeamName) // Route to search by team name
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    // Function to get a team with all its players
    func getTeamWithPlayers(req: Request) throws -> EventLoopFuture<Team.Public> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$players)
            .first()
            .unwrap(or: Abort(.notFound))
            .map { team in
                var publicTeam = team.asPublic()
                publicTeam.players = team.players.map { $0.asPublic() }
                return publicTeam
            }
    }

    // Function to get all teams with their players
    func getAllTeamsWithPlayers(req: Request) throws -> EventLoopFuture<[Team.Public]> {
        return Team.query(on: req.db)
            .with(\.$players)
            .all()
            .map { teams in
                teams.map { team in
                    var publicTeam = team.asPublic()
                    publicTeam.players = team.players.map { $0.asPublic() }
                    return publicTeam
                }
            }
    }

    // Function to search for a team by name
    func searchByTeamName(req: Request) throws -> EventLoopFuture<[Team]> {
        guard let teamName = req.parameters.get("value") else {
            throw Abort(.badRequest)
        }
        
        return Team.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$teamName ~~ teamName)
                group.filter(\.$sid ~~ teamName)
            }
            .all()
    }
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
