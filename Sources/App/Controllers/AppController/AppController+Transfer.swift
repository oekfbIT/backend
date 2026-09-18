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

    struct TransferPlayerOption: Content {
        let id: UUID?
        let sid: String
        let image: String?
        let name: String
        let number: String
        let team: UUID?
        let nationality: String
        let position: String
        let eligibility: PlayerEligibility
        let status: Bool?
        let isCaptain: Bool?
    }

    func setupTransferRoutes(on root: RoutesBuilder) {
        let transfers = root.grouped("transfer")

        // listing
        transfers.grouped(AdminOnlyMiddleware()).get(use: indexTransfers)

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

        try await authorize(transfer: transfer, req: req)

        return transfer
    }

    private func authorize(transfer: Transfer, req: Request) async throws {
        let user = try req.auth.require(User.self)
        if user.type == .admin { return }

        let userID = try user.requireID()
        let candidateIDs = [transfer.team, transfer.origin].compactMap { $0 }
        let ownsParticipant = try await Team.query(on: req.db)
            .filter(\.$id ~~ candidateIDs)
            .filter(\.$user.$id == userID)
            .count() > 0
        guard ownsParticipant else {
            throw Abort(.forbidden, reason: "This transfer does not belong to your account.")
        }
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

        guard let settings = try await TransferSettings.query(on: req.db).first(),
              settings.isTransferOpen else {
            throw Abort(.forbidden, reason: "Transfers are currently closed.")
        }

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

        guard let targetTeam = try await Team.find(dto.team, on: req.db) else {
            throw Abort(.notFound, reason: "Target team not found.")
        }
        try ApplicationAccess.authorize(team: targetTeam, req: req)

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

        try await transfer.create(on: req.db)

        player.transferred = true
        try await player.update(on: req.db)

        if let recipientEmail = player.email {
            do {
                _ = try EmailController()
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
        guard let originID = transfer.origin else {
            throw Abort(.forbidden, reason: "Transfer has no originating team.")
        }
        _ = try await ApplicationAccess.requireTeam(originID, req: req)

        transfer.status = .abgelehnt
        try await transfer.save(on: req.db)
        return .ok
    }

    // MARK: - GET /app/transfer/confirm/:id
    func confirmTransfer(req: Request) async throws -> Player.Public {
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
        guard let originID = transfer.origin ?? player.$team.id else {
            throw Abort(.forbidden, reason: "Transfer has no originating team.")
        }
        _ = try await ApplicationAccess.requireTeam(originID, req: req)

        transfer.origin = player.$team.id
        transfer.status = .angenommen

        player.$team.id = transfer.team
        player.transferred = true

        try await transfer.save(on: req.db)
        try await player.save(on: req.db)

        return player.asPublic()
    }

    // MARK: - GET /app/transfer/team/:teamID
    func getTransfersByTeam(req: Request) async throws -> [Transfer] {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid team ID.")
        }
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)

        return try await Transfer.query(on: req.db)
            .filter(\.$team == teamID)
            .all()
    }

    // MARK: - GET /app/transfer/player/:playerID
    func getTransfersByPlayer(req: Request) async throws -> [Transfer] {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid player ID.")
        }
        _ = try await ApplicationAccess.requirePlayer(playerID, req: req)

        return try await Transfer.query(on: req.db)
            .filter(\.$player == playerID)
            .all()
    }

    // MARK: - GET /app/transfer/options/:teamID
    func getTransfersOptions(req: Request) async throws -> [TransferPlayerOption] {
        guard let settings = try await TransferSettings.query(on: req.db).first(),
              settings.isTransferOpen == true
        else {
            throw Abort(.forbidden, reason: "Transfers are currently closed.")
        }

        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid team ID.")
        }
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)

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
            .map {
                TransferPlayerOption(
                    id: $0.id,
                    sid: $0.sid,
                    image: $0.image,
                    name: $0.name,
                    number: $0.number,
                    team: $0.$team.id,
                    nationality: $0.nationality,
                    position: $0.position,
                    eligibility: $0.eligibility,
                    status: $0.status,
                    isCaptain: $0.isCaptain
                )
            }
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
