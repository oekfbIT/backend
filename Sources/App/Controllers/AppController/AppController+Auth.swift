//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 04.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - AUTH / AUTHENTICATION ROUTES
extension AppController {

    struct UpdateAccountEmailRequest: Content {
        let email: String
    }

    func setupAccountRoutes(on route: RoutesBuilder) {
        let account = route.grouped("account")
        account.get(use: getAccount)
        account.patch("email", use: updateAccountEmail)
    }

    func getAccount(req: Request) throws -> User.Public {
        try req.auth.require(User.self).asPublic()
    }

    func updateAccountEmail(req: Request) async throws -> User.Public {
        let payload = try req.content.decode(UpdateAccountEmailRequest.self)
        let email = payload.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count <= 254 else {
            throw Abort(.badRequest, reason: "A valid email address is required.")
        }

        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let duplicate = try await User.query(on: req.db)
            .filter(\.$email == email)
            .filter(\.$id != userID)
            .first()
        guard duplicate == nil else {
            throw Abort(.conflict, reason: "This email address is already in use.")
        }

        user.email = email
        try await user.save(on: req.db)

        let teams = try await Team.query(on: req.db)
            .filter(\.$user.$id == userID)
            .all()
        for team in teams {
            team.usremail = email
            try await team.save(on: req.db)
        }

        return try user.asPublic()
    }

    /// /app/auth/login
    /// Uses `User.authenticator()` to authenticate by email/password and returns a `NewSession`.
    func setupAuthRoutes(on route: RoutesBuilder) throws {
        let auth = route.grouped("auth").grouped(ProtectedResponseMiddleware())

        // POST /app/auth/login
        let loginRoute = auth.grouped(User.authenticator())
        loginRoute.post("login", use: appLogin)

        // POST /app/auth/reset-password
        // TODO: implement password reset (lookup by email, generate new password or token, send via EmailController)
        auth.post("reset-password", use: resetPassword)
    }

    /// Mirrors `UserController.login` but under `/app/auth/login`.
    func appLogin(req: Request) throws -> EventLoopFuture<AppSession> {
        let user = try req.auth.require(User.self)
        let token = try user.createToken(source: .login)
        let userID = try user.requireID()

        // 1) Save token
        return token.save(on: req.db).flatMap {
            // 2) Fetch all teams that belong to this user
            Team.query(on: req.db)
                .filter(\.$user.$id == userID)
                 .with(\.$players)    // uncomment if you want players preloaded too
                 .with(\.$league)     // uncomment if you want league preloaded too
                .all()
        }
        .flatMapThrowing { teams in
            // 3) Build an allowlisted session payload. Full Team models contain
            // credentials and administrative contact data and must not be encoded.
            try AppSession(
                token: token.value,
                user: user.asPublic(),
                teams: teams.map { $0.asAppSessionTeam() }
            )
        }
    }

    /// Stub for password reset: route exists so the app can call it;
    /// implementation (email sending, temp password or token) comes later.
    func resetPassword(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // We intentionally return 501 for now so the client can distinguish
        // "route exists but not implemented yet" from "route not found".
        return req.eventLoop.future(.notImplemented)
    }
}
