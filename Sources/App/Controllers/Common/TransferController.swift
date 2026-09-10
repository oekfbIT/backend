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
        let adminRoute = route.grouped(
            Token.authenticator(),
            User.guardMiddleware(),
            AdminOnlyMiddleware()
        )

        // Read routes remain available to the existing clients. Generic mutation
        // routes are admin-only so they cannot bypass transfer-window checks.
        route.get(use: indexTransfers)
        route.get(":id", use: repository.getbyID)
        adminRoute.post("batch", use: repository.createBatch)
        adminRoute.delete(":id", use: repository.deleteID)
        adminRoute.patch(":id", use: repository.updateID)
        adminRoute.patch("batch", use: repository.updateBatch)

        // Custom routes
        route.get("reject", ":id", use: rejectTransfer)
        route.get("options", ":teamID", use: getTransfersOptions)
        route.get("isOpen", use: isTransferMarketOpen)

        route.post("create", use: createTransfer)               // client-facing DTO
        adminRoute.post("admin", "create", use: createTransferAdmin) // admin correction flow

        route.get("confirm", ":id", use: confirmTransfer)

        route.get("team", ":teamID", use: getTransfersByTeam)
        route.get("player", ":playerID", use: getTransfersByPlayer)
    }

    
    // ADD THIS in TransferController
    func indexTransfers(req: Request) throws -> EventLoopFuture<Page<Transfer>> {
        let pageRequest = try req.query.decode(PageRequest.self)

        return Transfer.query(on: req.db)
            .sort(\.$created, .descending) // newest first
            .paginate(pageRequest)
    }

    // GET /transfers/isOpen
    // This is intentionally read from the database on every request so clients
    // that stay logged in can refresh their access without signing in again.
    func isTransferMarketOpen(req: Request) async throws -> Response {
        let isOpen = try await TransferSettings.query(on: req.db).first()?.isTransferOpen ?? false
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json; charset=utf-8")
        headers.add(name: .cacheControl, value: "no-store, no-cache, must-revalidate")
        return Response(status: .ok, headers: headers, body: .init(string: isOpen ? "true" : "false"))
    }

    // POST /transfers/create
    // Accepts CreateTransferDTO { team, player, teamName, teamImage, playerName, playerImage }
    // - Ignores client-provided origin
    // - Allows only if player.transferred != true (nil or false is OK)
    // - Sets status = .warten, fills origin from player's current team
    func createTransfer(req: Request) throws -> EventLoopFuture<Transfer> {
        struct CreateTransferDTO: Content {
            let team: UUID         // target team
            let player: UUID
            let teamName: String?
            let teamImage: String?
            let playerName: String?
            let playerImage: String?
        }

        let dto = try req.content.decode(CreateTransferDTO.self)

        return TransferSettings.query(on: req.db).first().flatMap { settings in
            guard let settings = settings, settings.isTransferOpen else {
                return req.eventLoop.makeFailedFuture(Abort(.forbidden, reason: "Transfers are currently closed."))
            }

            return req.db.transaction { db in
                // 1) Load player (+ current team id)
                return Player.find(dto.player, on: db).unwrap(or: Abort(.notFound, reason: "Player not found.")).flatMap { player in
                    // Gate on the boolean flag
                    if player.transferred == true {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Player already has an active transfer."))
                    }

                    guard let originTeamID = player.$team.id else {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Player's current team not set."))
                    }

                    // 2) Load origin team details
                    return Team.find(originTeamID, on: db).unwrap(or: Abort(.notFound, reason: "Player's current team details not found.")).flatMap { originTeam in
                        return Team.find(dto.team, on: db).unwrap(or: Abort(.notFound, reason: "Target team not found.")).flatMap { targetTeam in
                            // Store authoritative image and team data from the database.
                            let transfer = Transfer(
                                team: dto.team,
                                player: dto.player,
                                status: .warten,
                                playerName: player.name,
                                playerImage: player.image ?? dto.playerImage ?? "",
                                teamName: targetTeam.teamName,
                                teamImage: targetTeam.logo,
                                origin: originTeam.id,
                                originName: originTeam.teamName,
                                originImage: originTeam.logo
                            )

                            // 4) Persist transfer + update player atomically
                            return transfer.create(on: db).flatMap {
                                player.transferred = true
                                return player.update(on: db).flatMap {
                                    // 5) Try email, but don't hard-fail if missing
                                    if let recipientEmail = player.email {
                                        do {
                                            _ = try self.emailController.sendTransferRequest(req: req, recipient: recipientEmail, transfer: transfer)
                                        } catch {
                                            req.logger.warning("Failed to send transfer email: \(error.localizedDescription)")
                                            // Intentionally do not fail the request
                                        }
                                    } else {
                                        req.logger.info("Player has no email; skipping transfer email.")
                                    }
                                    return req.eventLoop.makeSucceededFuture(transfer)
                                }
                            }
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

                let newTransfer = Transfer(
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
    func getTransfersOptions(_ req: Request) -> EventLoopFuture<[Player]> {
        // 1) Read the (singleton) transfer settings row
        return TransferSettings.query(on: req.db)
            .first()
            .flatMap { settings in
                // If no settings row or transfers closed → 403
                guard let s = settings, s.isTransferOpen == true else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.forbidden, reason: "Transfers are currently closed.")
                    )
                }

                // 2) Proceed with the original logic
                guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.badRequest, reason: "Invalid team ID.")
                    )
                }

                return Player.query(on: req.db)
                    .filter(\.$team.$id != teamID)
                    .group(.or) { group in
                        group.filter(\.$eligibility == .Gesperrt)
                        group.filter(\.$eligibility == .Spielberechtigt)
                    }
                    .filter(\.$email != nil)
                    .filter(\.$transferred != true)
                    .limit(200)
                    .all()
            }
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
