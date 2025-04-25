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
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
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

    func createNewRequest(req: Request) throws -> EventLoopFuture<PostponeRequest> {
        let newRequest = try req.content.decode(PostponeRequest.self)

        return newRequest.save(on: req.db).flatMap {
            guard let requesteeID = newRequest.requestee.id else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Missing requestee ID"))
            }

            let matchID = newRequest.$match.id

            let teamFuture = Team.find(requesteeID, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Requestee team not found"))

            let matchFuture = Match.find(matchID, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Match not found"))

            return teamFuture.and(matchFuture)
                .flatMapThrowing { opponentTeam, match -> (Team, Match) in
                    guard let email = opponentTeam.usremail,
                          let password = opponentTeam.usrpass else {
                        throw Abort(.badRequest, reason: "Missing email or password for opponent team")
                    }
                    return (opponentTeam, match)
                }
                .flatMap { opponentTeam, match in
                    print("sendingTO:", opponentTeam.usremail!)
                    match.postponerequest = true
                    return match.save(on: req.db).flatMap {
                        try! self.emailController.sendPostPone(
                            req: req,
                            cancellerName: newRequest.requester.teamName,
                            recipient: opponentTeam.usremail!,
                            match: match
                        ).map { _ in newRequest }
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
                    request.status = true

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



