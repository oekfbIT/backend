import Vapor
import Fluent

final class PlayerController: RouteCollection {
    let repository: StandardControllerRepository<Player>

    init(path: String) {
        self.repository = StandardControllerRepository<Player>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)

        route.patch(":id", "number", ":number", use: updatePlayerNumber)
        route.get("name", ":search", use: searchByName)
        route.get("internal", ":id", use: getPlayerWithIdentification)
        route.get("pending", use: getPlayersWithPendingEligibility)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // New create function that also creates a Rechnung
    func create(req: Request) throws -> EventLoopFuture<Player> {
        let player = try req.content.decode(Player.self)

        return player.create(on: req.db).flatMap {
            // Fetch the player again to access its properties, especially the $team relation
            Player.find(player.id, on: req.db).flatMap { savedPlayer in
                guard let savedPlayer = savedPlayer else {
                    return req.eventLoop.future(error: Abort(.notFound, reason: "Player not found after creation."))
                }
                
                guard let teamID = savedPlayer.$team.id else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Player must belong to a team."))
                }

                return Team.find(teamID, on: req.db).flatMap { team in
                    guard let team = team else {
                        return req.eventLoop.future(error: Abort(.notFound, reason: "Team not found."))
                    }

                    // Generate invoice number: current year + a random 5-digit number
                    let year = Calendar.current.component(.year, from: Date())
                    let randomFiveDigitNumber = String(format: "%05d", Int.random(in: 0..<100000))
                    let invoiceNumber = "\(year)\(randomFiveDigitNumber)"
                    
                    let rechnungAmount: Double = 5.0

                    let rechnung = Rechnung(
                        team: team.id!,
                        teamName: team.teamName,
                        number: invoiceNumber,
                        summ: rechnungAmount,
                        kennzeichen: team.teamName + " " + savedPlayer.sid + ": Anmeldung"
                    )

                    // Save the Rechnung and update the team's balance
                    return rechnung.save(on: req.db).flatMap {
                        if let currentBalance = team.balance {
                            team.balance = currentBalance - rechnungAmount
                        } else {
                            team.balance = -rechnungAmount
                        }

                        return team.save(on: req.db).map {
                            print("Rechnung created and team balance updated")
                            return savedPlayer
                        }
                    }
                }
            }
        }
    }


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

    func getPlayerWithIdentification(req: Request) -> EventLoopFuture<Player> {
        guard let playerID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing parameters"))
        }

        return Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound))
    }
    
    func getPlayersWithPendingEligibility(req: Request) -> EventLoopFuture<[Player.Public]> {
        return Player.query(on: req.db)
            .filter(\.$eligibility == .Warten)
            .all()
            .map { players in
                players.map { $0.asPublic() }
            }
    }
}
