//
//  File.swift
//  
//
//  Created by Alon Yakoby on 27.04.24.
//

import Foundation
import Vapor
import Fluent

final class RefereeController: RouteCollection {
    let repository: StandardControllerRepository<Referee>
    let emailController: EmailController
    
    init(path: String) {
        self.repository = StandardControllerRepository<Referee>(path: path)
        self.emailController = EmailController()
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: getbyID)
        route.get("user",":id", use: getbyUserID)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        route.get(":id", "topup", ":amount", use: topUpBalance)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func topUpBalance(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let refereeID = req.parameters.get("id", as: UUID.self),
              let amountString = req.parameters.get("amount"),
              let amount = Double(amountString), amount > 0 else {
            throw Abort(.badRequest, reason: "Invalid ID or amount")
        }
        
        return Referee.find(refereeID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { referee in
                referee.balance = (referee.balance ?? 0) + amount
                return referee.save(on: req.db).transform(to: .ok)
            }
    }

    
    func create(req: Request) throws -> EventLoopFuture<Referee> {
        let item = try req.content.decode(RefereeSignUpRequest.self)
        let userSignup = UserSignup(id: "REFUSER", firstName: item.first, lastName: item.last, email: item.email, password: item.password, type: .referee)

        do {
            let dbuser = try User.create(from: userSignup)
            
            return dbuser.save(on: req.db).flatMap { user in
                let ref = Referee(id: nil,
                                  userId: dbuser.id!,
                                  balance: 0,
                                  name: dbuser.firstName + " " + dbuser.lastName,
                                  identification: item.identification,
                                  image: item.image,
                                  nationality: item.nationality)
                
                do {
                    try self.emailController.sendRefLogin(req: req,
                                                     recipient: userSignup.email,
                                                     email: userSignup.email,
                                                     password: userSignup.password)
                } catch {
                    return req.eventLoop.makeFailedFuture(error)
                }

                // Continue with the saving process
                return ref.save(on: req.db).map { ref }
            }
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
    }

    func getbyID(req: Request) throws -> EventLoopFuture<Referee> {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Referee.query(on: req.db)
            .filter(\.$id == id)
            .with(\.$assignments)
            .first()
            .unwrap(or: Abort(.notFound))

    }
    
    func getbyUserID(req: Request) throws -> EventLoopFuture<Referee> {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Referee.query(on: req.db)
            .filter(\.$user.$id == id)
            .with(\.$assignments)
            .first()
            .unwrap(or: Abort(.notFound))

    }

}

struct RefereeSignUpRequest: Codable {
    var first: String
    var last: String
    var email: String
    var password: String
    var image: String
    var identification: String
    var nationality: String
}

