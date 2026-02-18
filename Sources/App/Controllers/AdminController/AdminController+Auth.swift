//
//  AdminController+AuthRoutes.swift
//  oekfbbackend
//
//  Assumptions:
//  - AdminController is mounted at something like "/admin" via `path`.
//  - You already have `User: ModelAuthenticatable` (email + passwordHash) working.
//  - You want ONLY admin users to be able to obtain a token from this endpoint.
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Auth Routes
extension AdminController {
    func setupAuthRoutes(on root: RoutesBuilder) {
        // POST /admin/auth/login
        // Uses Basic Auth (email + password) via User.authenticator()
        root.grouped("auth")
            .grouped(User.authenticator())
            .post("login", use: adminLogin)
    }

    // POST /admin/auth/login
    func adminLogin(req: Request) async throws -> NewSession {
        let user = try req.auth.require(User.self)

        guard user.type == .admin else {
            throw Abort(.forbidden, reason: "Only admins can log into the admin section.")
        }

        let token = try user.createToken(source: .login)
        try await token.save(on: req.db)

        return try NewSession(token: token.value, user: user.asPublic())
    }
}
