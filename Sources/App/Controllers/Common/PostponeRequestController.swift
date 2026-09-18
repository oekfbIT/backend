//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Vapor
import Fluent

final class PostponeRequestController: RouteCollection {
    let repository: StandardControllerRepository<PostponeRequest>
    let emailController: EmailController

    init(path: String) {
        self.repository = StandardControllerRepository<PostponeRequest>(path: path)
        self.emailController = EmailController()
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        let admin = route.grouped(AdminOnlyMiddleware())

        // Bulk and raw repository operations are administrative maintenance.
        admin.post("batch", use: repository.createBatch)

        // list / info routes
        admin.get(use: getAllPostponeRequestsSorted)
        admin.get("test", use: test)
        route.get("open", use: getOpenRequests)
        route.grouped("team", ":id")
            .grouped(TeamParameterAccessMiddleware(parameter: "id"))
            .get("all", use: getAllPostponeRequestsForTeam)

        // item routes
        admin.get(":id", "id", use: repository.getbyID)
        route.grouped(":id")
            .grouped(TeamParameterAccessMiddleware(parameter: "id"))
            .get(use: getTeamPostponeRequests)
        admin.delete(":id", use: repository.deleteID)

        admin.patch(":id", use: repository.updateID)
        admin.patch("batch", use: repository.updateBatch)

        // actions
        route.post(use: createNewRequest)
        route.post(":id", "approve", use: approveRequest)
        route.post(":id", "deny", use: denyRequest)
        admin.post(":id", "toggle", use: toggleStatus)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    /// Notifications are secondary to the request itself. The request has
    /// already been persisted when this is called, so a mail/push provider
    /// failure must not make the team retry and create duplicate requests.
    private func ignoreNotificationFailure(
        _ future: EventLoopFuture<Void>,
        req: Request,
        action: String
    ) -> EventLoopFuture<Void> {
        future.flatMapError { error in
            req.logger.warning("\(action) notification failed: \(error)")
            return req.eventLoop.makeSucceededFuture(())
        }
    }

    func test(req: Request) throws -> EventLoopFuture<[String]> {
        req.eventLoop.makeSucceededFuture(["Is Online"])
    }

    /// GET /postpone?per=300
    func getAllPostponeRequestsSorted(req: Request) throws -> EventLoopFuture<[PostponeRequest]> {
        let per = req.query[Int.self, at: "per"]

        var query = PostponeRequest.query(on: req.db)
            .sort(\.$created, .descending)

        if let per = per, per > 0 {
            query = query.range(..<per)
        }

        return query.all()
    }

    /// GET /postpone/team/:id/all
    func getAllPostponeRequestsForTeam(req: Request) async throws -> [PostponeRequest] {
        let teamID = try req.parameters.require("id", as: UUID.self)
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)

        return try await PostponeRequest.query(on: req.db)
            .sort(\.$created, .descending)
            .all()
            .filter {
                $0.requester.id == teamID || $0.requestee.id == teamID
            }
    }

    /// GET /postpone/open?teamID=...
    func getOpenRequests(req: Request) async throws -> [PostponeRequest] {
        guard let teamID = req.query[UUID.self, at: "teamID"] else {
            throw Abort(.badRequest, reason: "Missing or invalid teamID query param")
        }
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)

        return try await PostponeRequest.query(on: req.db)
            .filter(\.$status == true)
            .sort(\.$created, .descending)
            .all()
            .filter {
                $0.requester.id == teamID || $0.requestee.id == teamID
            }
    }

    /// GET /postpone/:id
    func getTeamPostponeRequests(req: Request) async throws -> [PostponeRequest] {
        let teamID = try req.parameters.require("id", as: UUID.self)
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)

        return try await PostponeRequest.query(on: req.db)
            .filter(\.$status == true)
            .sort(\.$created, .descending)
            .all()
            .filter {
                $0.requester.id == teamID || $0.requestee.id == teamID
            }
    }

    func createNewRequest(req: Request) async throws -> PostponeRequest {
        let newRequest = try req.content.decode(PostponeRequest.self)
        guard let requesterID = newRequest.requester.id else {
            throw Abort(.badRequest, reason: "Missing requester ID")
        }
        guard let requesteeID = newRequest.requestee.id else {
            throw Abort(.badRequest, reason: "Missing requestee ID")
        }
        guard requesterID != requesteeID else {
            throw Abort(.badRequest, reason: "Requester and requestee must be different teams.")
        }

        let requester = try await ApplicationAccess.requireTeam(requesterID, req: req)
        guard let requestee = try await Team.find(requesteeID, on: req.db) else {
            throw Abort(.notFound, reason: "Requestee team not found")
        }
        guard let match = try await Match.find(newRequest.$match.id, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }
        let participants = Set([match.$homeTeam.id, match.$awayTeam.id])
        guard participants == Set([requesterID, requesteeID]) else {
            throw Abort(.forbidden, reason: "The selected teams are not the participants in this match.")
        }

        // Do not trust client-supplied team names, logos, state or identifiers.
        newRequest.id = nil
        newRequest.requester = PublicTeamShort(
            id: requester.id,
            sid: requester.sid,
            logo: requester.logo,
            points: requester.points,
            teamName: requester.teamName,
            shortName: requester.shortName
        )
        newRequest.requestee = PublicTeamShort(
            id: requestee.id,
            sid: requestee.sid,
            logo: requestee.logo,
            points: requestee.points,
            teamName: requestee.teamName,
            shortName: requestee.shortName
        )
        newRequest.status = true
        newRequest.response = nil
        newRequest.responseDate = nil
        try await newRequest.save(on: req.db)

        match.postponerequest = true
        try await match.save(on: req.db)

        do {
            if let recipient = requestee.usremail {
                try await emailController.sendPostPone(
                    req: req,
                    postpone: newRequest,
                    cancellerName: requester.teamName,
                    recipient: recipient,
                    match: match
                ).get()
            }
            try await PostponePushNotifier.notifyRequestCreated(
                req: req,
                postponeRequest: newRequest,
                targetTeamId: requesteeID
            ).get()
        } catch {
            req.logger.warning("Postpone request notification failed: \(error)")
        }

        return newRequest
    }

    func approveRequest(req: Request) async throws -> PostponeRequest {
        let id = try req.parameters.require("id", as: UUID.self)
        let user = try req.auth.require(User.self)
        guard let request = try await PostponeRequest.find(id, on: req.db),
              let requesterID = request.requester.id,
              let requesteeID = request.requestee.id else { throw Abort(.notFound) }
        if user.type != .admin {
            guard user.type == .team,
                  let recipient = try await Team.find(requesteeID, on: req.db),
                  recipient.$user.id == user.id else { throw Abort(.forbidden) }
        }
        // Previously approved requests never acquire a retroactive charge.
        if request.response == true { return request }
        guard request.status, request.response == nil else {
            throw Abort(.conflict, reason: "Die Anfrage ist bereits abgeschlossen.")
        }
        let fees = try await FeeService.forRequest(req)
        guard let team = try await Team.find(requesterID, on: req.db),
              let match = try await Match.find(request.$match.id, on: req.db) else { throw Abort(.notFound) }
        try await PostponementFeeService(database: req.db).charge(requestID: id, team: team,
            fee: fees.fee(.matchPostponement))
        request.response = true
        request.responseDate = Date.viennaNow
        request.status = false
        try await request.update(on: req.db)
        do {
            if let email = team.usremail {
                try await self.emailController.approve(req: req, approverName: request.requestee.teamName,
                    recipient: email, match: match).get()
            }
            try await PostponePushNotifier.notifyRequestApproved(req: req,
                postponeRequest: request, targetTeamId: requesterID).get()
        } catch { req.logger.warning("Postpone approval notification failed: \(error)") }
        return request
    }


    func denyRequest(req: Request) async throws -> PostponeRequest {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let request = try await PostponeRequest.query(on: req.db)
            .with(\.$match)
            .filter(\.$id == id)
            .first()
        else {
            throw Abort(.notFound)
        }
        guard let requesterID = request.requester.id,
              let requesteeID = request.requestee.id else {
            throw Abort(.badRequest, reason: "Missing requester or requestee ID")
        }
        _ = try await ApplicationAccess.requireTeam(requesteeID, req: req)
        guard request.status, request.response == nil else {
            throw Abort(.conflict, reason: "Die Anfrage ist bereits abgeschlossen.")
        }
        guard let requester = try await Team.find(requesterID, on: req.db) else {
            throw Abort(.notFound, reason: "Requester team not found")
        }

        request.response = false
        request.responseDate = Date.viennaNow
        request.status = false
        try await request.update(on: req.db)

        do {
            if let email = requester.usremail {
                try await emailController.deny(
                    req: req,
                    denierName: request.requestee.teamName,
                    recipient: email,
                    match: request.match
                ).get()
            }
            try await PostponePushNotifier.notifyRequestDenied(
                req: req,
                postponeRequest: request,
                targetTeamId: requesterID
            ).get()
        } catch {
            req.logger.warning("Postpone denial notification failed: \(error)")
        }

        return request
    }

    func toggleStatus(req: Request) throws -> EventLoopFuture<PostponeRequest> {
        let id = try req.parameters.require("id", as: UUID.self)

        return PostponeRequest.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { request in
                request.status.toggle()
                return request.update(on: req.db).map { request }
            }
    }
}
