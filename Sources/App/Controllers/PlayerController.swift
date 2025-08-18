import Vapor
import Fluent

final class PlayerController: RouteCollection {
    let repository: StandardControllerRepository<Player>
    let emailController: EmailController
    
    init(path: String) {
        self.repository = StandardControllerRepository<Player>(path: path)
        self.emailController = EmailController()
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

        route.get("transfer", "name", ":search", use: searchTransferByName)
        route.get("name", ":search", use: searchByName)
        route.get("sid", ":sid", use: searchByID)

        route.get("internal", ":id", use: getPlayerWithIdentification)
        route.get("reject", ":id", use: sendUpdatePlayerEmail)
        route.get("pending", use: getPlayersWithEmail)
    
        route.post("copy", use: copyPlayer)
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
                    let year = Calendar.current.component(.year, from: Date.viennaNow)
                    let randomFiveDigitNumber = String(format: "%05d", Int.random(in: 0..<100000))
                    let invoiceNumber = "\(year)\(randomFiveDigitNumber)"
                    
                    let rechnungAmount: Double = -5.0

                    let rechnung = Rechnung(
                        team: team.id!,
                        teamName: team.teamName,
                        number: invoiceNumber,
                        summ: rechnungAmount,
                        topay: nil, kennzeichen: team.teamName + " " + savedPlayer.sid + ": Anmeldung"
                    )

                    // Save the Rechnung and update the team's balance
                    return rechnung.save(on: req.db).flatMap {
                        if let currentBalance = team.balance {
                            team.balance = currentBalance - 5
                        } else {
                            team.balance = -5
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
    
    // Handler
    func copyPlayer(req: Request) throws -> EventLoopFuture<Player.Public> {
        let payload = try req.content.decode(CopyPlayerRequest.self)

        let teamFuture = Team.find(payload.teamID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Destination team not found"))
        let playerFuture = Player.find(payload.playerID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Player not found"))

        return teamFuture.and(playerFuture).flatMap { _, original in
            let copy = Player(
                sid: original.sid,
                image: original.image,
                team_oeid: original.team_oeid,
                email: original.email,
                name: original.name,
                number: original.number,
                birthday: original.birthday,
                teamID: payload.teamID,
                nationality: original.nationality,
                position: original.position,
                eligibility: original.eligibility,
                registerDate: original.registerDate,
                identification: original.identification,
                status: original.status,
                isCaptain: original.isCaptain,
                bank: original.bank,
                blockdate: original.blockdate
            )
            copy.transferred = original.transferred

            return copy.save(on: req.db).flatMap {
                copy.$team.load(on: req.db).transform(to: copy.asPublic())
            }
        }
    }

    func sendUpdatePlayerEmail(req: Request) -> EventLoopFuture<HTTPStatus> {
        // Extract player ID from request parameters
        guard let playerID = req.parameters.get("id", as: UUID.self) else {
            req.logger.error("Invalid or missing player ID parameter")
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing parameters"))
        }

        // Find the player with the given ID
        return Player.find(playerID, on: req.db)
            .unwrap(or: {
                req.logger.error("Player with ID \(playerID) not found")
                return Abort(.notFound, reason: "Player not found")
            }())
            .flatMap { (player: Player) in
                // Update player information
                player.eligibility = .Warten
                player.image = ""
                player.identification = ""

                // Save the updated player
                return player.save(on: req.db).flatMap {
                    // Find the team associated with the player
                    return Team.find(player.$team.id, on: req.db)
                        .unwrap(or: {
                            req.logger.error("Team not found for player ID \(playerID)")
                            return Abort(.notFound, reason: "Team not found for player")
                        }())
                }.flatMap { (team: Team) -> EventLoopFuture<User> in
                    // Find the user associated with the team
                    return User.find(team.$user.id, on: req.db)
                        .unwrap(or: {
                            req.logger.error("User not found for team ID \(team.id?.uuidString ?? "unknown")")
                            return Abort(.notFound, reason: "User not found for team")
                        }())
                }.flatMap { (user: User) -> EventLoopFuture<HTTPStatus> in
                    // Log the user details
                    req.logger.info("Sending update player email to user \(user.email) for player ID \(playerID)")
                    // Send the update player email
                    do {
                        let emailFuture = try self.emailController.sendUpdatePlayerData(req: req, recipient: user.email, player: player)
                        return emailFuture.transform(to: .ok) // Transform the result to HTTPStatus.ok after email is sent
                    } catch {
                        req.logger.error("Error sending email: \(error.localizedDescription)")
                        return req.eventLoop.makeFailedFuture(error)
                    }
                }
            }
            .flatMapErrorThrowing { error in
                // Log the error or handle it appropriately
                req.logger.error("Failed to send email for player ID \(playerID): \(error.localizedDescription)")
                throw Abort(.internalServerError, reason: "Failed to send email")
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

    func searchTransferByName(req: Request) -> EventLoopFuture<[Player.Public]> {
        guard let searchValue = req.parameters.get("search") else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Missing search parameter"))
        }

        return Player.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$name ~~ searchValue)
                group.filter(\.$sid ~~ searchValue)
            }
            .filter(\.$email != nil) // Ensure email is not nil
            .filter(\.$email != "") // Ensure email is not empty
            .all()
            .map { players in
                players.map { $0.asPublic() }
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

    func searchByID(req: Request) -> EventLoopFuture<Player.Public> {
        guard let searchValue = req.parameters.get("sid") else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Missing search parameter"))
        }

        return Player.query(on: req.db)
            .filter(\.$sid ~~ searchValue)
            .first()
            .flatMap { player in
                guard let player = player else {
                    return req.eventLoop.future(error: Abort(.notFound, reason: "Player not found"))
                }
                return req.eventLoop.future(player.asPublic())
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
    
    func getPlayersWithEmail(req: Request) throws -> EventLoopFuture<[Player.Public]> {
        return Player.query(on: req.db)
            .filter(\.$email != nil)
            .filter(\.$email != "")
            .filter(\.$eligibility == .Warten)
            .all()
            .map { players in
                players.map { $0.asPublic() }
            }
    }

}

struct CopyPlayerRequest: Content {
    let teamID: UUID
    let playerID: UUID
}
