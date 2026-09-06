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

        // route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        // list / info routes
        route.get(use: getAllPostponeRequestsSorted)
        route.get("test", use: test)
        route.get("open", use: getOpenRequests)
        route.get("team", ":id", "all", use: getAllPostponeRequestsForTeam)

        // item routes
        route.get(":id", "id", use: repository.getbyID)
        route.get(":id", use: getTeamPostponeRequests)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)

        // actions
        route.post(use: createNewRequest)
        route.post(":id", "approve", use: approveRequest)
        route.post(":id", "deny", use: denyRequest)
        route.post(":id", "toggle", use: toggleStatus)
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
    func getAllPostponeRequestsForTeam(req: Request) throws -> EventLoopFuture<[PostponeRequest]> {
        let teamID = try req.parameters.require("id", as: UUID.self)

        return PostponeRequest.query(on: req.db)
            .sort(\.$created, .descending)
            .all()
            .map { requests in
                requests.filter {
                    $0.requester.id == teamID || $0.requestee.id == teamID
                }
            }
    }

    /// GET /postpone/open?teamID=...
    func getOpenRequests(req: Request) throws -> EventLoopFuture<[PostponeRequest]> {
        guard let teamID = req.query[UUID.self, at: "teamID"] else {
            throw Abort(.badRequest, reason: "Missing or invalid teamID query param")
        }

        return PostponeRequest.query(on: req.db)
            .filter(\.$status == true)
            .sort(\.$created, .descending)
            .all()
            .map { requests in
                requests.filter {
                    $0.requester.id == teamID || $0.requestee.id == teamID
                }
            }
    }

    /// GET /postpone/:id
    func getTeamPostponeRequests(req: Request) throws -> EventLoopFuture<[PostponeRequest]> {
        let teamID = try req.parameters.require("id", as: UUID.self)

        return PostponeRequest.query(on: req.db)
            .filter(\.$status == true)
            .sort(\.$created, .descending)
            .all()
            .map { requests in
                requests.filter {
                    $0.requester.id == teamID || $0.requestee.id == teamID
                }
            }
    }

    func createNewRequest(req: Request) throws -> EventLoopFuture<PostponeRequest> {
        let newRequest = try req.content.decode(PostponeRequest.self)
        newRequest.status = true

        guard let requesteeID = newRequest.requestee.id else {
            throw Abort(.badRequest, reason: "Missing requestee ID")
        }

        return newRequest.save(on: req.db).flatMap {
            let matchID = newRequest.$match.id

            let teamFuture = Team.find(requesteeID, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Requestee team not found"))

            let matchFuture = Match.find(matchID, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Match not found"))

            return teamFuture.and(matchFuture).flatMap { opponentTeam, match in
                match.postponerequest = true

                return match.save(on: req.db).flatMap {
                    let emailFuture: EventLoopFuture<Void> = {
                        guard let recipient = opponentTeam.usremail else {
                            req.logger.warning("Postpone request notification skipped: requestee has no email")
                            return req.eventLoop.makeSucceededFuture(())
                        }
                        do {
                            return try self.emailController.sendPostPone(
                                req: req,
                                postpone: newRequest,
                                cancellerName: newRequest.requester.teamName,
                                recipient: recipient,
                                match: match
                            ).transform(to: ())
                        } catch {
                            req.logger.warning("Unable to prepare postpone email: \(error)")
                            return req.eventLoop.makeSucceededFuture(())
                        }
                    }()

                    let pushFuture = PostponePushNotifier.notifyRequestCreated(
                        req: req,
                        postponeRequest: newRequest,
                        targetTeamId: requesteeID
                    )

                    return self.ignoreNotificationFailure(
                        emailFuture.and(pushFuture).transform(to: ()),
                        req: req,
                        action: "Postpone request"
                    ).transform(to: newRequest)
                }
            }
        }
    }

    func approveRequest(req: Request) throws -> EventLoopFuture<PostponeRequest> {
        let id = try req.parameters.require("id", as: UUID.self)

        return PostponeRequest.query(on: req.db)
            .with(\.$match)
            .filter(\.$id == id)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { request in
                guard let requesterID = request.requester.id else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.badRequest, reason: "Missing requester or match ID")
                    )
                }

                let matchID = request.$match.id

                let teamFuture = Team.find(requesterID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Requester team not found"))

                let matchFuture = Match.find(matchID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Match not found"))

                return teamFuture.and(matchFuture).flatMap { team, match in
                    request.response = true
                    request.responseDate = Date.viennaNow
                    request.status = false

                    return request.update(on: req.db)
                        .flatMap {
                            let emailFuture: EventLoopFuture<Void> = {
                                guard let email = team.usremail else {
                                    req.logger.warning("Postpone approval notification skipped: requester has no email")
                                    return req.eventLoop.makeSucceededFuture(())
                                }
                                do {
                                    return try self.emailController.approve(req: req, approverName: request.requestee.teamName, recipient: email, match: match).transform(to: ())
                                } catch {
                                    req.logger.warning("Unable to prepare postpone approval email: \(error)")
                                    return req.eventLoop.makeSucceededFuture(())
                                }
                            }()

                            let pushFuture = PostponePushNotifier.notifyRequestApproved(
                                req: req,
                                postponeRequest: request,
                                targetTeamId: requesterID
                            )

                            return self.ignoreNotificationFailure(emailFuture.and(pushFuture).transform(to: ()), req: req, action: "Postpone approval")
                                .transform(to: request)
                        }
                }
            }
    }

    func denyRequest(req: Request) throws -> EventLoopFuture<PostponeRequest> {
        let id = try req.parameters.require("id", as: UUID.self)

        return PostponeRequest.query(on: req.db)
            .with(\.$match)
            .filter(\.$id == id)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { request in
                guard let requesterID = request.requester.id else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.badRequest, reason: "Missing requester or match ID")
                    )
                }

                let matchID = request.$match.id

                let teamFuture = Team.find(requesterID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Requester team not found"))

                let matchFuture = Match.find(matchID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Match not found"))

                return teamFuture.and(matchFuture).flatMap { team, match in
                    request.response = false
                    request.responseDate = Date.viennaNow
                    request.status = false

                    return request.update(on: req.db)
                        .flatMap {
                            let emailFuture: EventLoopFuture<Void> = {
                                guard let email = team.usremail else {
                                    req.logger.warning("Postpone denial notification skipped: requester has no email")
                                    return req.eventLoop.makeSucceededFuture(())
                                }
                                do {
                                    return try self.emailController.deny(req: req, denierName: request.requestee.teamName, recipient: email, match: match).transform(to: ())
                                } catch {
                                    req.logger.warning("Unable to prepare postpone denial email: \(error)")
                                    return req.eventLoop.makeSucceededFuture(())
                                }
                            }()

                            let pushFuture = PostponePushNotifier.notifyRequestDenied(
                                req: req,
                                postponeRequest: request,
                                targetTeamId: requesterID
                            )

                            return self.ignoreNotificationFailure(emailFuture.and(pushFuture).transform(to: ()), req: req, action: "Postpone denial")
                                .transform(to: request)
                        }
                }
            }
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
