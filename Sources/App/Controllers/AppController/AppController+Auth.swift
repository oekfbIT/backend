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

    /// /app/auth/login
    /// Uses `User.authenticator()` to authenticate by email/password and returns a `NewSession`.
    func setupAuthRoutes(on route: RoutesBuilder) throws {
        let auth = route.grouped("auth")

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
            // 3) Build AppSession including full Team models
            try AppSession(
                token: token.value,
                user: user.asPublic(),
                teams: teams
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
