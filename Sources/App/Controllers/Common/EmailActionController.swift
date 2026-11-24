import Fluent
import Vapor

/// Only the fields needed by the email confirmation screens are returned.
struct EmailPostponeDetail: Content {
    let id: UUID
    let requester: PublicTeamShort
    let requestee: PublicTeamShort
    let status: Bool
    let response: Bool?
}

struct EmailTransferDetail: Content {
    let id: UUID
    let player: UUID
    let playerName: String
    let playerImage: String
    let team: UUID
    let teamName: String
    let teamImage: String
    let originImage: String?
    let status: TransferStatus
}

final class EmailActionController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let actions = routes.grouped("email-actions").grouped(ProtectedResponseMiddleware())
        let postpone = actions.grouped("postpone", ":id")
        postpone.get(use: getPostpone)
        postpone.post("approve", use: approvePostpone)
        postpone.post("deny", use: denyPostpone)
        let transfer = actions.grouped("transfer", ":id")
        transfer.get(use: getTransfer)
        transfer.post("confirm", use: confirmTransfer)
        transfer.post("reject", use: rejectTransfer)
    }

    private func authorizedID(_ req: Request, kind: String) throws -> UUID {
        let id = try req.parameters.require("id", as: UUID.self)
        try EmailActionLink.require(req, kind: kind, id: id)
        return id
    }

    func getPostpone(_ req: Request) async throws -> EmailPostponeDetail {
        let id = try authorizedID(req, kind: "postpone")
        guard let item = try await PostponeRequest.find(id, on: req.db) else { throw Abort(.notFound) }
        return EmailPostponeDetail(id: id, requester: item.requester, requestee: item.requestee,
                                   status: item.status, response: item.response)
    }

    func approvePostpone(_ req: Request) async throws -> EmailPostponeDetail {
        _ = try authorizedID(req, kind: "postpone")
        let item = try await PostponeRequestController(path: "postpone").approveRequest(req: req, fromEmail: true)
        return EmailPostponeDetail(id: try item.requireID(), requester: item.requester,
                                   requestee: item.requestee, status: item.status, response: item.response)
    }

    func denyPostpone(_ req: Request) async throws -> EmailPostponeDetail {
        _ = try authorizedID(req, kind: "postpone")
        let item = try await PostponeRequestController(path: "postpone").denyRequest(req: req, fromEmail: true)
        return EmailPostponeDetail(id: try item.requireID(), requester: item.requester,
                                   requestee: item.requestee, status: item.status, response: item.response)
    }

    func getTransfer(_ req: Request) async throws -> EmailTransferDetail {
        let id = try authorizedID(req, kind: "transfer")
        guard let item = try await Transfer.find(id, on: req.db) else { throw Abort(.notFound) }
        return EmailTransferDetail(id: id, player: item.player, playerName: item.playerName,
            playerImage: item.playerImage, team: item.team, teamName: item.teamName,
            teamImage: item.teamImage, originImage: item.originImage, status: item.status)
    }

    func confirmTransfer(_ req: Request) async throws -> EmailTransferDetail {
        try await respondToTransfer(req, accept: true)
    }

    func rejectTransfer(_ req: Request) async throws -> EmailTransferDetail {
        try await respondToTransfer(req, accept: false)
    }

    private func respondToTransfer(_ req: Request, accept: Bool) async throws -> EmailTransferDetail {
        let id = try authorizedID(req, kind: "transfer")
        let transfer = try await SeasonTransfers.respond(id: id, accept: accept, req: req, fromEmail: true)
        return EmailTransferDetail(id: id, player: transfer.player, playerName: transfer.playerName,
            playerImage: transfer.playerImage, team: transfer.team, teamName: transfer.teamName,
            teamImage: transfer.teamImage, originImage: transfer.originImage, status: transfer.status)
    }
}
