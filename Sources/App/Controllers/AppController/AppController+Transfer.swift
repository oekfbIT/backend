//
//  AppController+Transfer.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 18.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - Transfer Endpoints (App)
extension AppController {

    func setupTransferRoutes(on root: RoutesBuilder) {
        let transfers = root.grouped("transfer")

        // listing
        transfers.get(use: indexTransfers)

        // single
        transfers.get(":id", use: getTransferByID)

        // create (app flow)
        transfers.post("create", use: createTransfer)

        // confirm / reject
        transfers.get("confirm", ":id", use: confirmTransfer)
        transfers.get("reject", ":id", use: rejectTransfer)

        // relations
        transfers.get("team", ":teamID", use: getTransfersByTeam)
        transfers.get("player", ":playerID", use: getTransfersByPlayer)

        // options
        transfers.get("options", ":teamID", use: getTransfersOptions)
        // ✅ NEW: transfer market open check
        transfers.get("isOpen", use: isTransferMarketOpen)

    }

    // MARK: - GET /app/transfer
    func indexTransfers(req: Request) async throws -> Page<Transfer> {
        let pageRequest = try req.query.decode(PageRequest.self)

        return try await Transfer.query(on: req.db)
            .sort(\.$created, .descending)
            .paginate(pageRequest)
    }

    // MARK: - GET /app/transfer/:id
    func getTransferByID(req: Request) async throws -> Transfer {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid transfer ID.")
        }

        guard let transfer = try await Transfer.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Transfer not found.")
        }

        return transfer
    }

    // MARK: - POST /app/transfer/create
    func createTransfer(req: Request) async throws -> Transfer {
        struct CreateTransferDTO: Content {
            let team: UUID
            let player: UUID
            let teamName: String?
            let teamImage: String?
            let playerName: String?
            let playerImage: String?
        }

        let dto = try req.content.decode(CreateTransferDTO.self)

        guard let player = try await Player.find(dto.player, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        if player.transferred == true {
            throw Abort(.badRequest, reason: "Player already has an active transfer.")
        }

        guard let originTeamID = player.$team.id,
              let originTeam = try await Team.find(originTeamID, on: req.db) else {
            throw Abort(.badRequest, reason: "Player's current team not set.")
        }

        let transfer = Transfer(
            team: dto.team,
            player: dto.player,
            status: .warten,
            playerName: dto.playerName ?? player.name,
            playerImage: dto.playerImage ?? player.image ?? "",
            teamName: dto.teamName ?? "",
            teamImage: dto.teamImage ?? "",
            origin: originTeam.id,
            originName: originTeam.teamName,
            originImage: originTeam.logo
        )

        try await transfer.create(on: req.db)

        player.transferred = true
        try await player.update(on: req.db)

        if let recipientEmail = player.email {
            do {
                try EmailController()
                    .sendTransferRequest(req: req, recipient: recipientEmail, transfer: transfer)
            } catch {
                req.logger.warning("Failed to send transfer email: \(error)")
            }
        }

        return transfer
    }

    // MARK: - GET /app/transfer/reject/:id
    func rejectTransfer(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self),
              let transfer = try await Transfer.find(id, on: req.db)
        else {
            throw Abort(.notFound, reason: "Transfer not found.")
        }

        transfer.status = .abgelehnt
        try await transfer.save(on: req.db)
        return .ok
    }

    // MARK: - GET /app/transfer/confirm/:id
    func confirmTransfer(req: Request) async throws -> Player {
        guard let settings = try await TransferSettings.query(on: req.db).first(),
              settings.isTransferOpen == true
        else {
            throw Abort(.badRequest, reason: "Transfers are currently closed.")
        }

        guard let id = req.parameters.get("id", as: UUID.self),
              let transfer = try await Transfer.find(id, on: req.db),
              let player = try await Player.find(transfer.player, on: req.db)
        else {
            throw Abort(.notFound, reason: "Transfer or player not found.")
        }

        transfer.origin = player.$team.id
        transfer.status = .angenommen

        player.$team.id = transfer.team
        player.transferred = true

        try await transfer.save(on: req.db)
        try await player.save(on: req.db)

        return player
    }

    // MARK: - GET /app/transfer/team/:teamID
    func getTransfersByTeam(req: Request) async throws -> [Transfer] {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid team ID.")
        }

        return try await Transfer.query(on: req.db)
            .filter(\.$team == teamID)
            .all()
    }

    // MARK: - GET /app/transfer/player/:playerID
    func getTransfersByPlayer(req: Request) async throws -> [Transfer] {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid player ID.")
        }

        return try await Transfer.query(on: req.db)
            .filter(\.$player == playerID)
            .all()
    }

    // MARK: - GET /app/transfer/options/:teamID
    func getTransfersOptions(req: Request) async throws -> [Player] {
        guard let settings = try await TransferSettings.query(on: req.db).first(),
              settings.isTransferOpen == true
        else {
            throw Abort(.forbidden, reason: "Transfers are currently closed.")
        }

        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid team ID.")
        }

        return try await Player.query(on: req.db)
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
    
    // MARK: - GET /app/transfer/isOpen
    func isTransferMarketOpen(req: Request) async throws -> Bool {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            // defensive default: closed
            return false
        }

        return settings.isTransferOpen
    }

}
