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

    struct TeamTransferHistoryEntry: Content {
        let transfer: Transfer
        let seasonName: String?
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
        transfers.post("withdraw", ":id", use: withdrawTransfer)

        // relations
        transfers.get("team", ":teamID", use: getTransfersByTeam)
        transfers.get("team", ":teamID", "history", use: getTeamTransferHistory)
        transfers.get("player", ":playerID", use: getTransfersByPlayer)

        // options
        transfers.get("options", ":teamID", use: getTransfersOptions)
        // ✅ NEW: transfer market open check
        transfers.get("isOpen", use: isTransferMarketOpen)
        transfers.get("isOpen", ":teamID", use: isTeamTransferWindowOpen)

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
        let dto = try req.content.decode(TransferRequest.self)
        return try await SeasonTransfers.request(playerID: dto.player, targetID: dto.team, req: req)
    }

    func rejectTransfer(req: Request) async throws -> HTTPStatus {
        let id = try req.parameters.require("id", as: UUID.self)
        _ = try await SeasonTransfers.respond(id: id, accept: false, req: req)
        return .ok
    }

    func withdrawTransfer(req: Request) async throws -> HTTPStatus {
        let id = try req.parameters.require("id", as: UUID.self)
        try await SeasonTransfers.withdraw(id: id, req: req)
        return .noContent
    }

    func confirmTransfer(req: Request) async throws -> Player.Public {
        let id = try req.parameters.require("id", as: UUID.self)
        let transfer = try await SeasonTransfers.respond(id: id, accept: true, req: req)
        guard let player = try await Player.find(transfer.player, on: req.db) else { throw Abort(.notFound) }
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

    func getTeamTransferHistory(req: Request) async throws -> [TeamTransferHistoryEntry] {
        let transfers = try await getTransfersByTeam(req: req)
        let seasonIDs = Set(transfers.compactMap(\.seasonID))
        var names: [UUID: String] = [:]
        if !seasonIDs.isEmpty {
            let seasons = try await Season.query(on: req.db).filter(\.$id ~~ Array(seasonIDs)).all()
            for season in seasons { names[try season.requireID()] = season.name }
        }
        return transfers.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }.map {
            TeamTransferHistoryEntry(transfer: $0, seasonName: $0.seasonID.flatMap { names[$0] })
        }
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
        let teamID = try req.parameters.require("teamID", as: UUID.self)
        let team = try await ApplicationAccess.requireTeam(teamID, req: req)
        return try await SeasonTransfers.options(for: team, on: req.db)
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
        try await SeasonTransfers.isOpen(on: req.db)
    }

    func isTeamTransferWindowOpen(req: Request) async throws -> Bool {
        let teamID = try req.parameters.require("teamID", as: UUID.self)
        let team = try await ApplicationAccess.requireTeam(teamID, req: req)
        return try await SeasonTransfers.primarySeason(for: team, on: req.db)?.transferOpen == true
    }

}
