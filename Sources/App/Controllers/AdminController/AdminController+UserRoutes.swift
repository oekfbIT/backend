//
//  AdminController+UserRoutes.swift
//
//  Admin Users (index + CRUD + password reset + bundle)
//
//  Endpoints:
//  - GET    /admin/users/admins                 -> [User.Public]
//  - GET    /admin/users/:id                    -> User.Public
//  - POST   /admin/users                        -> User.Public
//  - PATCH  /admin/users/:id                    -> User.Public
//  - DELETE /admin/users/:id                    -> HTTPStatus
//  - POST   /admin/users/:id/reset-password     -> HTTPStatus
//  - GET    /admin/users/:id/bundle             -> AdminUserBundle
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin User Routes
extension AdminController {

    func setupUserRoutes(on root: RoutesBuilder) {
        let users = root.grouped("users")

        users.get("admins", use: getAllAdminUsers)
        users.get(":id", use: getUserByID)

        users.post(use: adminCreateUser)
        users.patch(":id", use: patchUser)

        users.delete(":id", use: deleteAdminUser)

        users.post(":id", "reset-password", use: resetForgottenPassword)

        users.get(":id", "bundle", use: getUserBundleWithTeams)
    }
}

// MARK: - DTOs
extension AdminController {

    struct AdminCreateUserRequest: Content {
        let type: UserType
        let firstName: String
        let lastName: String
        let email: String
        let tel: String?
        let password: String
        let verified: Bool?
        let userID: String? // optional override; otherwise generated
    }

    struct PatchUserRequest: Content {
        let type: UserType?
        let firstName: String?
        let lastName: String?
        let email: String?
        let tel: String?
        let verified: Bool?
        // NOTE: no password here (use reset endpoint)
    }

    struct ResetPasswordRequest: Content {
        let newPassword: String
    }

    struct AdminUserBundle: Content {
        let user: User.Public
        let teams: [AdminTeamOverview]
    }
}

// MARK: - Handlers
extension AdminController {

    // GET /admin/users/admins
    func getAllAdminUsers(req: Request) async throws -> [User.Public] {
        let admins = try await User.query(on: req.db)
            .filter(\.$type == .admin)
            .sort(\.$lastName, .ascending)
            .sort(\.$firstName, .ascending)
            .all()

        return try admins.map { try $0.asPublic() }
    }

    // GET /admin/users/:id
    func getUserByID(req: Request) async throws -> User.Public {
        let user = try await requireUser(req: req, param: "id")
        return try user.asPublic()
    }

    // POST /admin/users
    func adminCreateUser(req: Request) async throws -> User.Public {
        let body = try req.content.decode(AdminCreateUserRequest.self)

        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { throw Abort(.badRequest, reason: "email is required.") }

        let first = body.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = body.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { throw Abort(.badRequest, reason: "firstName is required.") }
        guard !last.isEmpty else { throw Abort(.badRequest, reason: "lastName is required.") }

        guard body.password.count >= 6 else {
            throw Abort(.badRequest, reason: "password must be at least 6 characters.")
        }

        // enforce uniqueness (DB unique constraint also exists)
        if let _ = try await User.query(on: req.db).filter(\.$email == email).first() {
            throw Abort(.conflict, reason: "email already exists.")
        }

        let uid = (body.userID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? String.randomString(length: 10)

        let hashed = try Bcrypt.hash(body.password)

        let user = User(
            id: nil,
            userID: uid,
            type: body.type,
            firstName: first,
            lastName: last,
            verified: body.verified ?? false,
            email: email,
            tel: body.tel,
            passwordHash: hashed
        )

        try await user.save(on: req.db)
        return try user.asPublic()
    }

    // PATCH /admin/users/:id
    func patchUser(req: Request) async throws -> User.Public {
        let user = try await requireUser(req: req, param: "id")
        let body = try req.content.decode(PatchUserRequest.self)

        if let t = body.type { user.type = t }

        if let v = body.firstName {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { throw Abort(.badRequest, reason: "firstName cannot be empty.") }
            user.firstName = s
        }

        if let v = body.lastName {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { throw Abort(.badRequest, reason: "lastName cannot be empty.") }
            user.lastName = s
        }

        if let v = body.email {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !s.isEmpty else { throw Abort(.badRequest, reason: "email cannot be empty.") }

            // if changed, ensure unique
            if s != user.email {
                if let _ = try await User.query(on: req.db).filter(\.$email == s).first() {
                    throw Abort(.conflict, reason: "email already exists.")
                }
                user.email = s
            }
        }

        if let v = body.tel {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            user.tel = s.isEmpty ? nil : s
        }

        if let v = body.verified { user.verified = v }

        try await user.save(on: req.db)
        return try user.asPublic()
    }

    // DELETE /admin/users/:id
    // (named "delete admin user" — this deletes any user id; keep middleware/admin checks outside)
    func deleteAdminUser(req: Request) async throws -> HTTPStatus {
        let user = try await requireUser(req: req, param: "id")
        try await user.delete(on: req.db)
        return .ok
    }

    // POST /admin/users/:id/reset-password
    func resetForgottenPassword(req: Request) async throws -> HTTPStatus {
        let user = try await requireUser(req: req, param: "id")
        let body = try req.content.decode(ResetPasswordRequest.self)

        guard body.newPassword.count >= 6 else {
            throw Abort(.badRequest, reason: "newPassword must be at least 6 characters.")
        }

        user.passwordHash = try Bcrypt.hash(body.newPassword)
        try await user.save(on: req.db)
        return .ok
    }

    // GET /admin/users/:id/bundle
    func getUserBundleWithTeams(req: Request) async throws -> AdminUserBundle {
        let user = try await requireUser(req: req, param: "id")
        let userId = try user.requireID()

        let teams = try await Team.query(on: req.db)
            .filter(\.$user.$id == userId)
            .sort(\.$teamName, .ascending)
            .all()

        let mapped: [AdminTeamOverview] = try teams.map { t in
            AdminTeamOverview(
                id: try t.requireID(),
                sid: t.sid ?? "",
                league: t.$league.id,
                points: t.points,
                logo: t.logo,
                name: t.teamName,
                shortName: t.shortName
            )
        }

        return AdminUserBundle(user: try user.asPublic(), teams: mapped)
    }
}

// MARK: - Helpers
private extension AdminController {

    func requireUser(req: Request, param: String) async throws -> User {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid user ID.")
        }
        guard let user = try await User.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }
        return user
    }
}
