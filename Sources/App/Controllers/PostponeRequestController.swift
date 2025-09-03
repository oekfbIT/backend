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
        
//        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
//        route.get(":id", "index", use: repository.getbyID)
        route.get(":id", use: getTeamPostponeRequests)
        route.get(":id", "id", use: repository.getbyID)
        route.get("test", use: test)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        
        route.get("open", use: getOpenRequests)
        route.post(use: createNewRequest)
        route.post(":id", "approve", use: approveRequest)
        route.post(":id", "deny", use: denyRequest)
        route.post(":id", "toggle", use: toggleStatus)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func test(req: Request) throws -> EventLoopFuture<[String]> {
        return req.eventLoop.makeSucceededFuture(["Is Online"])
    }

    func getOpenRequests(req: Request) throws -> EventLoopFuture<[PostponeRequest]> {
        guard let teamID = req.query[UUID.self, at: "teamID"] else {
            throw Abort(.badRequest, reason: "Missing or invalid teamID query param")
        }

        return PostponeRequest.query(on: req.db)
            .filter(\.$status == true)
            .all()
            .map { requests in
                requests.filter {
                    $0.requester.id == teamID || $0.requestee.id == teamID
                }
            }
    }
    
    func getTeamPostponeRequests(req: Request) throws -> EventLoopFuture<[PostponeRequest]> {
        let teamID = try req.parameters.require("id", as: UUID.self)

        return PostponeRequest.query(on: req.db)
            .filter(\.$status == true)
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
        return newRequest.save(on: req.db).flatMap {
            guard let requesteeID = newRequest.requestee.id else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Missing requestee ID"))
            }

            let matchID = newRequest.$match.id

            let teamFuture = Team.find(requesteeID, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Requestee team not found"))

            let matchFuture = Match.find(matchID, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Match not found"))

            return teamFuture.and(matchFuture).flatMap { opponentTeam, match in
                guard let recipient = opponentTeam.usremail else {
                    return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Missing opponent team email"))
                }

                match.postponerequest = true

                return match.save(on: req.db).flatMap {
                    // structured log with the request-id header if present
                    req.logger.info("POST /postpone -> sending email", metadata: [
                        "recipient": .string(recipient),
                        "matchID": .string(match.id?.uuidString ?? "nil"),
                        "requestID": .string(req.headers.first(name: "request-id") ?? "n/a")
                    ])

                    // send email; EmailController.sendPostPone currently throws, so wrap in do/catch
                    do {
                        return try self.emailController
                            .sendPostPone(
                                req: req,
                                postpone: newRequest,
                                cancellerName: newRequest.requester.teamName,
                                recipient: recipient,
                                match: match
                            )
                            .map { _ in newRequest } // success: return the created request
                            .flatMapError { error in
                                // surface the error to the client and logs
                                req.logger.report(error: error)
                                return req.eventLoop.makeFailedFuture(
                                    Abort(.internalServerError, reason: "Failed to send postpone email: \(error.localizedDescription)")
                                )
                            }
                    } catch {
                        req.logger.report(error: error)
                        return req.eventLoop.makeFailedFuture(
                            Abort(.internalServerError, reason: "Failed to prepare postpone email: \(error.localizedDescription)")
                        )
                    }
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
                    return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Missing requester or match ID"))
                }
                
                let matchID = request.$match.id

                let teamFuture = Team.find(requesterID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Requester team not found"))

                let matchFuture = Match.find(matchID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Match not found"))

                return teamFuture.and(matchFuture).flatMap { team, match in
                    guard let email = team.usremail else {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Missing team email"))
                    }

                    request.response = true
                    request.responseDate = Date.viennaNow
                    request.response = true

                    return request.update(on: req.db)
                        .flatMap {
                            do {
                                return try self.emailController.approve(
                                    req: req,
                                    approverName: request.requestee.teamName,
                                    recipient: email,
                                    match: match
                                ).map { _ in request }
                            } catch {
                                return req.eventLoop.makeFailedFuture(error)
                            }
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
                let requesterID = request.requester.id
                let matchID = request.$match.id

                let teamFuture = Team.find(requesterID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Requester team not found"))

                let matchFuture = Match.find(matchID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Match not found"))

                return teamFuture.and(matchFuture).flatMap { team, match in
                    guard let email = team.usremail else {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Missing team email"))
                    }

                    request.response = false
                    request.responseDate = Date.viennaNow
                    request.status = true

                    return request.update(on: req.db)
                        .flatMap {
                            do {
                                return try self.emailController.deny(
                                    req: req,
                                    denierName: request.requestee.teamName,
                                    recipient: email,
                                    match: match
                                ).map { _ in request }
                            } catch {
                                return req.eventLoop.makeFailedFuture(error)
                            }
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



