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

    init(path: String) {
        self.repository = StandardControllerRepository<Transfer>(path: path)
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

        route.get(use: indexTransfers)
        route.get(":id", use: repository.getbyID)

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
        let isOpen = try await SeasonTransfers.isOpen(on: req.db)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json; charset=utf-8")
        headers.add(name: .cacheControl, value: "no-store, no-cache, must-revalidate")
        return Response(status: .ok, headers: headers, body: .init(string: isOpen ? "true" : "false"))
    }

    func createTransfer(req: Request) async throws -> Transfer {
        let dto = try req.content.decode(TransferRequest.self)
        return try await SeasonTransfers.request(playerID: dto.player, targetID: dto.team, req: req)
    }

    func rejectTransfer(req: Request) async throws -> HTTPStatus {
        let id = try req.parameters.require("id", as: UUID.self)
        _ = try await SeasonTransfers.respond(id: id, accept: false, req: req)
        return .ok
    }

    func createTransferAdmin(req: Request) async throws -> Player {
        let dto = try req.content.decode(TransferRequest.self)
        let transfer = try await SeasonTransfers.create(playerID: dto.player, targetID: dto.team, req: req, admin: true)
        guard let player = try await Player.find(transfer.player, on: req.db) else { throw Abort(.notFound) }
        return player
    }

    func confirmTransfer(req: Request) async throws -> Player {
        let id = try req.parameters.require("id", as: UUID.self)
        let transfer = try await SeasonTransfers.respond(id: id, accept: true, req: req)
        guard let player = try await Player.find(transfer.player, on: req.db) else { throw Abort(.notFound) }
        return player
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

    func getTransfersOptions(_ req: Request) async throws -> [Player] {
        let teamID = try req.parameters.require("teamID", as: UUID.self)
        let team = try await ApplicationAccess.requireTeam(teamID, req: req)
        return try await SeasonTransfers.options(for: team, on: req.db)
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
