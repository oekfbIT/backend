//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent


final class TransferController: RouteCollection {
    let repository: StandardControllerRepository<Transfer>
    let emailcontroller: EmailController
    init(path: String) {
        self.repository = StandardControllerRepository<Transfer>(path: path)
        self.emailcontroller = EmailController()
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post("batch", use: repository.createBatch)
        
        // Existing routes
        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        
        // New routes
        route.get("reject", ":id", use: rejectTransfer)
        route.get("options", ":teamID", use: getTransfersOptions)
        
        route.post("create", use: createTransfer)
        route.post("admin", "create", use: createTransferAdmin)
        
        route.get("confirm", ":id", use: confirmTransfer)
        
        route.get("team",":teamID", use: getTransfersByTeam)
        route.get("player",":playerID", use: getTransfersByPlayer)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // Route to create a transfer and set its status to "warten"
    func createTransfer(req: Request) -> EventLoopFuture<Transfer> {
        do {
            // Decode the incoming transfer data
            let transfer = try req.content.decode(Transfer.self)

            // Check for existing transfer with the same player and accepted status
            return Transfer.query(on: req.db)
                .filter(\.$player == transfer.player)
                .group(.or) { group in
                    group.filter(\.$status == .angenommen)
                }
                .first()
                .flatMap { existingTransfer -> EventLoopFuture<Transfer> in
                    if let _ = existingTransfer {
                        // If an existing transfer is found, return a failed future
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Dieser Spieler wurde diese Saison schon einen Transfer gehabt."))
                    } else {
                        // No existing transfer found, proceed to create a new one
                        return Player.find(transfer.player, on: req.db).flatMap { player -> EventLoopFuture<Transfer> in
                            guard let player = player, let playerTeamID = player.$team.id else {
                                return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player or player's current team not found."))
                            }

                            return Team.find(playerTeamID, on: req.db).flatMap { playerTeam -> EventLoopFuture<Transfer> in
                                guard let playerTeam = playerTeam else {
                                    return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player's current team details not found."))
                                }

                                // Set the origin fields to the player's current team
                                var newTransfer = transfer
                                newTransfer.status = .warten
                                newTransfer.origin = playerTeam.id
                                newTransfer.originName = playerTeam.teamName
                                newTransfer.originImage = playerTeam.logo

                                // Save the new transfer to the database
                                return newTransfer.create(on: req.db).flatMap { _ -> EventLoopFuture<Transfer> in
                                    if let recipientEmail = player.email {
                                        do {
                                            try self.emailcontroller.sendTransferRequest(req: req, recipient: recipientEmail, transfer: newTransfer)
                                        } catch {
                                            return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Failed to send transfer email."))
                                        }
                                    } else {
                                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Player does not have an email address."))
                                    }

                                    return req.eventLoop.makeSucceededFuture(newTransfer)
                                }
                            }
                        }
                    }
                }
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
    }
    
    // Route to reject a transfer by ID
    func rejectTransfer(req: Request) -> EventLoopFuture<HTTPStatus> {
        return Transfer.find(req.parameters.get("id"), on: req.db).flatMap { transfer in
            guard let transfer = transfer else {
                return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Transfer not found."))
            }
            transfer.status = .abgelent
            return transfer.save(on: req.db).transform(to: .ok)
        }
    }
        
    func createTransferAdmin(req: Request) -> EventLoopFuture<Player> {
        do {
            // Decode the incoming transfer data
            let transfer = try req.content.decode(Transfer.self)

            // Set the status to 'angenommen'
            var newTransfer = transfer
            newTransfer.status = .angenommen

            // Save the new transfer to the database
            return Player.find(newTransfer.player, on: req.db).flatMap { player -> EventLoopFuture<Player> in
                guard let player = player, let playerTeamID = player.$team.id else {
                    return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player or player's current team not found."))
                }

                return Team.find(playerTeamID, on: req.db).flatMap { playerTeam -> EventLoopFuture<Player> in
                    guard let playerTeam = playerTeam else {
                        return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player's current team details not found."))
                    }

                    // Set the origin fields to the player's current team
                    newTransfer.origin = playerTeam.id
                    newTransfer.originName = playerTeam.teamName
                    newTransfer.originImage = playerTeam.logo

                    // Update the player's team ID to the new team ID
                    player.$team.id = newTransfer.team

                    // Save the updated player and transfer
                    return player.save(on: req.db).flatMap { _ in
                        return newTransfer.create(on: req.db).map {
                            player
                        }
                    }
                }
            }
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
    }

    // Route to confirm a transfer
    func confirmTransfer(req: Request) -> EventLoopFuture<Player> {
        return TransferSettings.query(on: req.db).first().flatMap { settings in
            guard let settings = settings else {
                return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "TransferSettings not found."))
            }

            guard settings.isTransferOpen else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Außerhalb Saison nicht möglich einen Transfer zu machen."))
            }

            return Transfer.find(req.parameters.get("id"), on: req.db).flatMap { transfer in
                guard let transfer = transfer else {
                    return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Transfer not found."))
                }

                return Player.find(transfer.player, on: req.db).flatMap { player in
                    guard let player = player else {
                        return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player not found."))
                    }
                    
                    transfer.origin = player.$team.id
                    transfer.status = .angenommen
                    transfer.save(on: req.db)
                    
                    
                    player.$team.id = transfer.team
                    player.transferred = true
                    
                    return player.save(on: req.db).map { player }
                }
            }
        }
    }

    // Route to get all transfers by team ID
    func getTransfersByTeam(req: Request) -> EventLoopFuture<[Transfer]> {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid team ID."))
        }

        return Transfer.query(on: req.db)
            .filter(\.$team == teamID)
            .all()
    }

    func getTransfersOptions(req: Request) -> EventLoopFuture<[Player]> {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid team ID."))
        }

        return Player.query(on: req.db)
            .filter(\.$team.$id != teamID) // Exclude players from the specified team
            .group(.or) { group in
                group.filter(\.$eligibility == .Gesperrt)
                group.filter(\.$eligibility == .Spielberechtigt)
            }
            .filter(\.$email != nil )
            .filter(\.$transferred != true)
            .limit(200)
            .all()
        
    }

    // Route to get all transfers by player ID
    func getTransfersByPlayer(req: Request) -> EventLoopFuture<[Transfer]> {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid player ID."))
        }

        return Transfer.query(on: req.db).filter(\.$player == playerID).all()
    }

}
