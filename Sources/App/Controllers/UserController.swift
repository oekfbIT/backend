//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Vapor
import Fluent

struct PasswordUpdateRequest: Content {
    let currentPassword: String
    let newPassword: String
}

final class UserController: RouteCollection {
    let repository: StandardControllerRepository<User>
    let emailController: EmailController  // Add this line

    init(path: String) {
        self.repository = StandardControllerRepository<User>(path: path)
        self.emailController = EmailController()  // Initialize EmailController
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        route.post(use: signup)
        route.post("batch", use: signupBatch)
        route.grouped(User.authenticator()).post("login", use: login)
        
        route.get(use: repository.index)
        route.get("teams", use: getTeamUserIndex)
        route.get(":id", use: repository.getbyID)
        route.get("team", ":id", use: getUserWithTeam)
        route.delete(":id", use: repository.deleteID)
        
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)

        // Add this line for password update
        route.patch("password", ":id", use: updatePassword)

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
    
    
    func getTeamUserIndex(req: Request) throws -> EventLoopFuture<[User]> {
        User.query(on: req.db)
            .filter(\.$type == .team)
            .with(\.$teams)
            .all()
    }

    // Function to get a team with all its players
    func getUserWithTeam(req: Request) throws -> EventLoopFuture<User> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        return User.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$teams)
            .first()
            .unwrap(or: Abort(.notFound))
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
                return verificationToken.save(on: req.db).flatMap { _ in
                    // Send email asynchronously
                    return req.eventLoop.submit {
                        try self.emailController.sendEmailWithData(req: req, recipient: userSignup.email, email: userSignup.email, password: userSignup.password)
                    }.flatMap {
                        return req.eventLoop.makeSucceededFuture(())
                    }
                }
            }
        }.flatMapThrowing {
            return try NewSession(token: token.value, user: user.asPublic())
        }
    }

    func signupBatch(req: Request) throws -> EventLoopFuture<[NewSession]> {
        let userSignups = try req.content.decode([UserSignup].self)
        
        // Map each user signup to an EventLoopFuture<NewSession>
        let signupFutures = try userSignups.map { userSignup -> EventLoopFuture<NewSession> in
            let user = try User.create(from: userSignup)
            var token: Token!
            
            // Check if user already exists
            return checkIfUserExists(userSignup.email, req: req).flatMap { exists in
                guard !exists else {
                    return req.eventLoop.future(error: UserError.emailTaken)
                }
                
                // Save user to database
                return user.save(on: req.db).flatMap { _ -> EventLoopFuture<Void> in
                    // Create token for user
                    guard let newToken = try? user.createToken(source: .signup) else {
                        return req.eventLoop.future(error: Abort(.internalServerError))
                    }
                    token = newToken
                    
                    // Save token to database
                    return token.save(on: req.db)
                }.flatMap { _ -> EventLoopFuture<Void> in
                    let verificationToken = UserVerificationToken(userID: user.id!)
                    
                    // Save verification token to database
                    return verificationToken.save(on: req.db).flatMap { _ in
                        // Send email to user with registration details
                        return req.eventLoop.submit {
                            try self.emailController.sendEmailWithData(req: req, recipient: userSignup.email, email: userSignup.email, password: userSignup.password)
                        }.flatMap {
                            // Return NewSession after sending email
                            return req.eventLoop.makeSucceededFuture(())
                        }
                    }
                }.flatMapThrowing {
                    // Return NewSession with token and user details
                    return try NewSession(token: token.value, user: user.asPublic())
                }
            }
        }
        
        // Return a future that completes when all signupFutures are successful
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
    
    func updatePassword(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // Extract the user ID from the request parameters
        guard let userID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "User ID is missing or invalid")
        }

        // Decode the password update request body
        let updateRequest = try req.content.decode(PasswordUpdateRequest.self)

        // Fetch the user from the database using the user ID
        return User.find(userID, on: req.db).flatMap { user in
            guard let user = user else {
                return req.eventLoop.future(error: Abort(.notFound, reason: "User not found"))
            }

            // Verify the current password
            do {
                guard try user.verify(password: updateRequest.currentPassword) else {
                    return req.eventLoop.future(error: Abort(.unauthorized, reason: "Current password is incorrect"))
                }

                // Hash the new password and update the user's password
                user.passwordHash = try Bcrypt.hash(updateRequest.newPassword)
            } catch {
                return req.eventLoop.future(error: error)
            }

            // Fetch the team associated with the user
            return Team.query(on: req.db).filter(\.$user.$id == userID).first().flatMap { team in
                if let team = team {
                    // Update the team's usrpass field
                    team.usrpass = updateRequest.newPassword
                    
                    // Save both the user and the team
                    return team.save(on: req.db).flatMap {
                        return user.save(on: req.db).transform(to: .ok)
                    }
                } else {
                    // If no team is found, just save the user
                    return user.save(on: req.db).transform(to: .ok)
                }
            }
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


