import Vapor
import Fluent

final class PlayerController: RouteCollection {
    let repository: StandardControllerRepository<Player>

    init(path: String) {
        self.repository = StandardControllerRepository<Player>(path: path)
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

        // New route for updating player number
        route.patch(":id", "number", ":number", use: updatePlayerNumber)
        
        // New route for searching players by name
        route.get("name", ":search", use: searchByName)
        
        // New route for getting a normal player with identification
        route.get("internal", ":id", use: getPlayerWithIdentification)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // New handler function to update player's number
    func updatePlayerNumber(req: Request) -> EventLoopFuture<Player.Public> {
        guard let playerID = req.parameters.get("id", as: UUID.self),
              let newNumber = req.parameters.get("number") else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing parameters"))
        }

        return Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { player in
                player.number = newNumber
                return player.save(on: req.db).map { player.asPublic() }
            }
    }

    // New handler function to search players by name
    func searchByName(req: Request) -> EventLoopFuture<[Player.Public]> {
        guard let searchValue = req.parameters.get("search") else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Missing search parameter"))
        }

        return Player.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$name ~~ searchValue)
                group.filter(\.$sid ~~ searchValue)
            }
            .all()
            .map { players in
                players.map { $0.asPublic() }
            }
    }

    // New handler function to get a player with identification
    func getPlayerWithIdentification(req: Request) -> EventLoopFuture<Player> {
        guard let playerID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing parameters"))
        }

        return Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound))
    }
}

extension Player: Mergeable {
    func merge(from other: Player) -> Player {
        var merged = self
        merged.id = other.id
        merged.sid = other.sid
        merged.name = other.name
        merged.number = other.number
        merged.birthday = other.birthday
        merged.$team.id = other.$team.id
        merged.nationality = other.nationality
        merged.position = other.position
        merged.eligibility = other.eligibility
        merged.registerDate = other.registerDate
        merged.identification = other.identification
        merged.status = other.status
        return merged
    }
}
