//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Vapor
import Fluent

final class UserController: RouteCollection {
    let repository: StandardControllerRepository<User>
    
    init(path: String) {
        self.repository = StandardControllerRepository<User>(path: path)
    }
    
    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        route.post(use: signup)
        route.post("batch", use: signupBatch)
        route.grouped(User.authenticator()).post("login", use: login)
        
        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)
        
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
    }
    
    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    private func checkIfUserExists(_ email: String, req: Request) -> EventLoopFuture<Bool> {
        User.query(on: req.db)
            .filter(\.$email == email)
            .first()
            .map { $0 != nil }
    }
    
    
    func signup(req: Request) throws -> EventLoopFuture<NewSession> {
        let userSignup = try req.content.decode(UserSignup.self)
        let user = try User.create(from: userSignup)
        var token: Token!

        return checkIfUserExists(userSignup.email, req: req).flatMap { exists in
            guard !exists else {
                return req.eventLoop.future(error: UserError.emailTaken)
            }
            return user.save(on: req.db).flatMap { _ -> EventLoopFuture<Void> in
                guard let newToken = try? user.createToken(source: .signup) else {
                    return req.eventLoop.future(error: Abort(.internalServerError))
                }
                token = newToken
                return token.save(on: req.db)
            }.flatMap { _ -> EventLoopFuture<Void> in
                let verificationToken = UserVerificationToken(userID: user.id!)
                return verificationToken.save(on: req.db).map { _ in
                    DispatchQueue.global(qos: .background).async {
                        // Send Email to User with the password.
                    }
                }
            }
        }.flatMapThrowing {
            return try NewSession(token: token.value, user: user.asPublic())
        }
    }
    
    func signupBatch(req: Request) throws -> EventLoopFuture<[NewSession]> {
        let userSignups = try req.content.decode([UserSignup].self)
        let signupFutures = try userSignups.map { userSignup -> EventLoopFuture<NewSession> in
            let user = try User.create(from: userSignup)
            var token: Token!

            return checkIfUserExists(userSignup.email, req: req).flatMap { exists in
                guard !exists else {
                    return req.eventLoop.future(error: UserError.emailTaken)
                }
                return user.save(on: req.db).flatMap { _ -> EventLoopFuture<Void> in
                    guard let newToken = try? user.createToken(source: .signup) else {
                        return req.eventLoop.future(error: Abort(.internalServerError))
                    }
                    token = newToken
                    return token.save(on: req.db)
                }.flatMap { _ -> EventLoopFuture<Void> in
                    let verificationToken = UserVerificationToken(userID: user.id!)
                    return verificationToken.save(on: req.db).map { _ in
                        DispatchQueue.global(qos: .background).async {
                            // Send Email to User with the password.
                        }
                    }
                }.flatMapThrowing {
                    return try NewSession(token: token.value, user: user.asPublic())
                }
            }
        }

        return EventLoopFuture.whenAllSucceed(signupFutures, on: req.eventLoop)
    }

    
    func login(req: Request) throws -> EventLoopFuture<NewSession> {
        let user = try req.auth.require(User.self)
        let token = try user.createToken(source: .login)
        print(req)
        return token.save(on: req.db).flatMapThrowing {
            NewSession(token: token.value, user: try user.asPublic())
        }
    }
    
    /*
     TODO: [X]
     [] USER WITH TEAM LIST
     [] USER WITH LIST OF ALL TICKETS
     [] UPDATE CLEARANCE LEVEL
     */
}

extension User: Mergeable {
    func merge(from other: User) -> User {
        let merged = self
        merged.firstName = other.firstName
        merged.lastName = other.lastName
        merged.userID = other.userID
        merged.email = other.email
        merged.passwordHash = other.passwordHash
        merged.type = other.type
        return merged
    }
}

