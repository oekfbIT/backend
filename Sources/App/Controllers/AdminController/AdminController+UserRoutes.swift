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

        let readable = users.grouped(PermissionMiddleware(.usersRead))
        readable.get("admins", use: getAllAdminUsers)
        readable.get("team", use: getAllTeamUsers)
        readable.get(":id", use: getUserByID)

        users.grouped(PermissionMiddleware(.usersCreate)).post(use: adminCreateUser)
        users.grouped(PermissionMiddleware(.usersUpdate)).patch(":id", use: patchUser)

        users.grouped(PermissionMiddleware(.usersDelete)).delete(":id", use: deleteAdminUser)

        users.grouped(PermissionMiddleware(.usersUpdate)).post(":id", "reset-password", use: resetForgottenPassword)

        readable.get(":id", "bundle", use: getUserBundleWithTeams)

        // Permission discovery and assignment.
        users.get("permissions", "catalog", use: getPermissionCatalog)
        readable.get(":id", "permissions", use: getUserPermissions)
        users.grouped(PermissionMiddleware(.usersUpdate))
            .put(":id", "permissions", use: replaceUserPermissions)
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
        let permissions: [UserPermission]?
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
    
    struct AdminTeamUserIndexItem: Content {
        let user: User.Public
        let teamNames: [String]
        let teamIds: [UUID]
    }

    struct ResetPasswordRequest: Content {
        let newPassword: String
    }

    struct ReplacePermissionsRequest: Content {
        let permissions: [UserPermission]
    }

    struct UserPermissionsResponse: Content {
        let userId: UUID
        let permissions: [UserPermission]
    }

    struct AdminUserBundle: Content {
        let user: User.Public
        let teams: [AdminTeamOverview]
    }
}

// MARK: - Handlers
extension AdminController {

    func getPermissionCatalog(req: Request) async throws -> [UserPermission] {
        UserPermission.allCases
    }

    func getUserPermissions(req: Request) async throws -> UserPermissionsResponse {
        let user = try await requireUser(req: req, param: "id")
        guard user.type == .admin else {
            throw Abort(.badRequest, reason: "Permissions can only be assigned to admin users.")
        }
        return try permissionResponse(for: user)
    }

    func replaceUserPermissions(req: Request) async throws -> UserPermissionsResponse {
        let user = try await requireUser(req: req, param: "id")
        guard user.type == .admin else {
            throw Abort(.badRequest, reason: "Permissions can only be assigned to admin users.")
        }
        let body = try req.content.decode(ReplacePermissionsRequest.self)
        user.permissions = Array(Set(body.permissions)).sorted { $0.rawValue < $1.rawValue }
        try await user.save(on: req.db)
        return try permissionResponse(for: user)
    }

    private func permissionResponse(for user: User) throws -> UserPermissionsResponse {
        UserPermissionsResponse(
            userId: try user.requireID(),
            permissions: Array(user.effectivePermissions).sorted { $0.rawValue < $1.rawValue }
        )
    }
    
    // GET /admin/users/admins
    // GET /admin/users/team
    func getAllTeamUsers(req: Request) async throws -> [AdminTeamUserIndexItem] {
        let teamUsers = try await User.query(on: req.db)
            .filter(\.$type == .team)
            .sort(\.$lastName, .ascending)
            .sort(\.$firstName, .ascending)
            .all()

        let userIds: [UUID] = teamUsers.compactMap { $0.id }
        if userIds.isEmpty { return [] }

        // Load all teams for these users in one query
        let teams = try await Team.query(on: req.db)
            .filter(\.$user.$id ~~ userIds)
            .sort(\.$teamName, .ascending)
            .all()

        // Group teams by userId
        var teamsByUserId: [UUID: [Team]] = [:]
        teamsByUserId.reserveCapacity(userIds.count)

        for t in teams {
            if let uid = t.$user.id {
                teamsByUserId[uid, default: []].append(t)
            }
        }

        // Map users to index rows
        return try teamUsers.map { u in
            let uid = try u.requireID()
            let userTeams = teamsByUserId[uid] ?? []

            return AdminTeamUserIndexItem(
                user: try u.asPublic(),
                teamNames: userTeams.map { $0.teamName },
                teamIds: userTeams.compactMap { $0.id }
            )
        }
    }

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
        user.permissions = body.type == .admin ? Array(Set(body.permissions ?? [])) : []

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
