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
    func appLogin(req: Request) throws -> EventLoopFuture<NewSession> {
        let user = try req.auth.require(User.self)
        let token = try user.createToken(source: .login)

        return token.save(on: req.db).flatMapThrowing {
            NewSession(token: token.value, user: try user.asPublic())
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
