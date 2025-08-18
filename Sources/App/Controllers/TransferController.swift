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
    let emailController: EmailController

    init(path: String) {
        self.repository = StandardControllerRepository<Transfer>(path: path)
        self.emailController = EmailController()
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))

        // Generic CRUD from your repository
        route.post("batch", use: repository.createBatch)
        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)

        // Custom routes
        route.get("reject", ":id", use: rejectTransfer)
        route.get("options", ":teamID", use: getTransfersOptions)

        route.post("create", use: createTransfer)               // client-facing DTO
        route.post("admin", "create", use: createTransferAdmin) // admin flow

        route.get("confirm", ":id", use: confirmTransfer)

        route.get("team", ":teamID", use: getTransfersByTeam)
        route.get("player", ":playerID", use: getTransfersByPlayer)
    }

    // POST /transfers/create
    // Accepts CreateTransferDTO (snake_case accepted), sets status=warten, fills origin from current player's team, emails the player.
    func createTransfer(req: Request) throws -> EventLoopFuture<Transfer> {
        let dto = try req.content.decode(CreateTransferDTO.self)

        // Prevent duplicates where a transfer was already accepted for this player this season
        return Transfer.query(on: req.db)
            .filter(\.$player == dto.player)
            .filter(\.$status == .angenommen)
            .first()
            .flatMap { existing in
                guard existing == nil else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.badRequest, reason: "Dieser Spieler wurde diese Saison schon einen Transfer gehabt.")
                    )
                }

                // Fetch player -> current team (origin)
                return Player.find(dto.player, on: req.db).flatMap { player in
                    guard let player = player, let playerTeamID = player.$team.id else {
                        return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player or player's current team not found."))
                    }

                    return Team.find(playerTeamID, on: req.db).flatMap { playerTeam in
                        guard let playerTeam = playerTeam else {
                            return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player's current team details not found."))
                        }

                        var newTransfer = Transfer(
                            team: dto.team,
                            player: dto.player,
                            status: .warten,
                            playerName: dto.playerName,
                            playerImage: dto.playerImage,
                            teamName: dto.teamName,
                            teamImage: dto.teamImage,
                            origin: playerTeam.id,
                            originName: playerTeam.teamName,
                            originImage: playerTeam.logo
                        )

                        return newTransfer.create(on: req.db).flatMap {
                            // Send email if we have one; surface error if sending fails to match previous behavior.
                            if let recipientEmail = player.email {
                                do {
                                    try self.emailController.sendTransferRequest(req: req, recipient: recipientEmail, transfer: newTransfer)
                                    return req.eventLoop.makeSucceededFuture(newTransfer)
                                } catch {
                                    return req.eventLoop.makeFailedFuture(
                                        Abort(.internalServerError, reason: "Failed to send transfer email.")
                                    )
                                }
                            } else {
                                return req.eventLoop.makeFailedFuture(
                                    Abort(.badRequest, reason: "Player does not have an email address.")
                                )
                            }
                        }
                    }
                }
            }
    }

    // GET /transfers/reject/:id
    func rejectTransfer(req: Request) -> EventLoopFuture<HTTPStatus> {
        Transfer.find(req.parameters.get("id"), on: req.db).flatMap { transfer in
            guard let transfer = transfer else {
                return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Transfer not found."))
            }
            transfer.status = .abgelehnt
            return transfer.save(on: req.db).transform(to: .ok)
        }
    }

    // POST /transfers/admin/create
    // Accepts the same DTO, marks accepted immediately and moves the player to the new team.
    func createTransferAdmin(req: Request) throws -> EventLoopFuture<Player> {
        let dto = try req.content.decode(CreateTransferDTO.self)

        return Player.find(dto.player, on: req.db).flatMap { player in
            guard let player = player, let currentTeamID = player.$team.id else {
                return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player or player's current team not found."))
            }

            return Team.find(currentTeamID, on: req.db).flatMap { playerTeam in
                guard let playerTeam = playerTeam else {
                    return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Player's current team details not found."))
                }

                var newTransfer = Transfer(
                    team: dto.team,
                    player: dto.player,
                    status: .angenommen,
                    playerName: dto.playerName,
                    playerImage: dto.playerImage,
                    teamName: dto.teamName,
                    teamImage: dto.teamImage,
                    origin: playerTeam.id,
                    originName: playerTeam.teamName,
                    originImage: playerTeam.logo
                )

                // Move player to new team, then persist transfer
                player.$team.id = dto.team
                player.transferred = true

                return player.save(on: req.db).flatMap {
                    newTransfer.create(on: req.db).transform(to: player)
                }
            }
        }
    }

    // GET /transfers/confirm/:id
    func confirmTransfer(req: Request) -> EventLoopFuture<Player> {
        TransferSettings.query(on: req.db).first().flatMap { settings in
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

                    // Save origin from player's current team at confirmation time too (defensive)
                    transfer.origin = player.$team.id
                    transfer.status = .angenommen

                    player.$team.id = transfer.team
                    player.transferred = true

                    return transfer.save(on: req.db).flatMap {
                        player.save(on: req.db).map { player }
                    }
                }
            }
        }
    }

    // GET /transfers/team/:teamID
    func getTransfersByTeam(req: Request) -> EventLoopFuture<[Transfer]> {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid team ID."))
        }
        return Transfer.query(on: req.db)
            .filter(\.$team == teamID)
            .all()
    }

    // GET /transfers/options/:teamID
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
            .filter(\.$email != nil)
            .filter(\.$transferred != true)
            .limit(200)
            .all()
    }

    // GET /transfers/player/:playerID
    func getTransfersByPlayer(req: Request) -> EventLoopFuture<[Transfer]> {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid player ID."))
        }
        return Transfer.query(on: req.db)
            .filter(\.$player == playerID)
            .all()
    }
}
