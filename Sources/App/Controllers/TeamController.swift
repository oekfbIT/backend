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
        
        route.get(":id", "players", use: getTeamWithPlayers)
        route.get("withPlayers", use: getAllTeamsWithPlayers)
        
        route.get("search", ":value", use: searchByTeamName)
        
        route.get(":id", "topup", ":amount", use: topUpBalance)
        route.post(":id", "league", ":leagueID", use: assignNewLeague) 
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
    
    // Function to top up the balance
    func topUpBalance(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let teamID = req.parameters.get("id", as: UUID.self),
              let amount = req.parameters.get("amount", as: Double.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { team in
                team.balance = (team.balance ?? 0) + amount
                return team.save(on: req.db).transform(to: .ok)
            }
    }

    // Function to assign a new league
    func assignNewLeague(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let teamID = req.parameters.get("id", as: UUID.self),
              let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { league in
                return Team.find(teamID, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { team in
                        team.$league.id = leagueID
                        return team.save(on: req.db).transform(to: .ok)
                    }
            }
    }

}

extension Team: Mergeable {
    func merge(from other: Team) -> Team {
        var merged = self
        merged.points = other.points
        merged.logo = other.logo
        merged.$league.id = other.$league.id
        merged.$user.id = other.$user.id
        merged.teamName = other.teamName
        merged.foundationYear = other.foundationYear
        merged.membershipSince = other.membershipSince
        merged.averageAge = other.averageAge
        merged.coach = other.coach
        merged.captain = other.captain
        merged.trikot = other.trikot
        merged.balance = other.balance
        merged.usremail = other.usremail
        merged.usrpass = other.usrpass
        merged.usrtel = other.usrtel
        return merged
    }
}

