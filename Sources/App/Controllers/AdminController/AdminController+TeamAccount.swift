import Foundation
import Vapor
import Fluent

// Serializes account mutations within this server, including email delivery.
// Mongo standalone deployments do not support database transactions.
private actor TeamAccountGate {
    static let shared = TeamAccountGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension AdminController {
    struct TeamAccountUser: Content {
        let id: UUID
        let userID: String
        let firstName: String
        let lastName: String
        let email: String
        let tel: String?
        let verified: Bool?
        let type: UserType

        init(_ user: User) throws {
            id = try user.requireID()
            userID = user.userID
            firstName = user.firstName
            lastName = user.lastName
            email = user.email
            tel = user.tel
            verified = user.verified
            type = user.type
        }
    }

    struct TeamAccountTeam: Content {
        let id: UUID
        let name: String
        let sid: String?
    }

    struct TeamAccountResponse: Content {
        let user: TeamAccountUser?
        let teams: [TeamAccountTeam]
        var previousUserDeleted: Bool = false
        var cleanupPending: Bool = false
    }

    struct AssignTeamAccountRequest: Content {
        let userId: UUID
        let expectedUserId: UUID?
    }

    struct ResetTeamAccountResponse: Content {
        let emailSent: Bool
        let cleanupPending: Bool
    }

    struct ResetTeamAccountRequest: Content {
        let expectedUserId: UUID
    }

    func setupTeamAccountRoutes(on root: RoutesBuilder) {
        root.get("users", "selection", use: searchTeamAccounts)
        root.get("teams", ":id", "user", use: getTeamAccount)
        root.put("teams", ":id", "user", use: assignTeamAccount)
        root.post("teams", ":id", "user", "reset-password", use: resetTeamAccountPassword)
    }

    // Paginate before building DTOs. Never encode User or User.Public here.
    func searchTeamAccounts(req: Request) async throws -> Page<TeamAccountUser> {
        let query = (try? req.query.get(String.self, at: "q"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let page = max(1, (try? req.query.get(Int.self, at: "page")) ?? 1)
        let per = min(50, max(1, (try? req.query.get(Int.self, at: "per")) ?? 10))
        let users = User.query(on: req.db).filter(\.$type == .team)
        // Match all words across names/email; exact UUID lookup also supported.
        for word in query.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            users.group(.or) { group in
                group.filter(\.$email ~~ Self.teamAccountSearchPattern(word))
                group.filter(\.$firstName ~~ Self.teamAccountSearchPattern(word))
                group.filter(\.$lastName ~~ Self.teamAccountSearchPattern(word))
                group.filter(\.$userID ~~ Self.teamAccountSearchPattern(word))
                if let id = UUID(uuidString: word) { group.filter(\.$id == id) }
            }
        }
        let result = try await users.sort(\.$email).sort(\.$id)
            .paginate(PageRequest(page: page, per: per))
        return Page(items: try result.items.map(TeamAccountUser.init), metadata: result.metadata)
    }

    func getTeamAccount(req: Request) async throws -> TeamAccountResponse {
        let team = try await accountTeam(req)
        return try await accountResponse(userId: team.$user.id, db: req.db)
    }

    func assignTeamAccount(req: Request) async throws -> TeamAccountResponse {
        let body = try req.content.decode(AssignTeamAccountRequest.self)
        await TeamAccountGate.shared.acquire()
        do {
            let result = try await assignTeamAccount(req: req, body: body)
            await TeamAccountGate.shared.release()
            return result
        } catch {
            await TeamAccountGate.shared.release()
            throw error
        }
    }

    private func assignTeamAccount(req: Request, body: AssignTeamAccountRequest) async throws -> TeamAccountResponse {
        let team = try await accountTeam(req)
        guard team.$user.id == body.expectedUserId else {
            throw Abort(.conflict, reason: "Die Zuordnung wurde geändert. Bitte neu laden.")
        }
        guard let selected = try await User.find(body.userId, on: req.db), selected.type == .team else {
            throw Abort(.badRequest, reason: "Bitte einen bestehenden Mannschaftsbenutzer auswählen.")
        }
        if team.$user.id == body.userId {
            return try await accountResponse(userId: body.userId, db: req.db)
        }
        let previousId = team.$user.id
        // Persist the new owner first: cleanup must never leave this team without an owner.
        team.$user.id = body.userId
        team.usrpass = nil
        try await team.save(on: req.db)

        var deleted = false
        var cleanupPending = false
        if let previousId {
            do {
                if let previous = try await User.find(previousId, on: req.db), previous.type == .team {
                    let teams = try await Team.query(on: req.db).filter(\.$user.$id == previousId).count()
                    let referees = try await Referee.query(on: req.db).filter(\.$user.$id == previousId).count()
                    if teams == 0 && referees == 0 {
                        try await Token.query(on: req.db).filter(\.$user.$id == previousId).delete()
                        try await UserVerificationToken.query(on: req.db).filter(\.$userID == previousId).delete()
                        try await previous.delete(on: req.db)
                        deleted = true
                    }
                }
            } catch {
                // Assignment succeeded. Report cleanup separately so the UI does not retry the move.
                cleanupPending = true
                req.logger.error("Previous team account cleanup failed for \(previousId)")
            }
        }
        var result = try await accountResponse(userId: body.userId, db: req.db)
        result.previousUserDeleted = deleted
        result.cleanupPending = cleanupPending
        return result
    }

    // The Mongo driver embeds contains filters directly into a regular expression.
    static func teamAccountSearchPattern(_ text: String) -> String {
        "(?i)" + NSRegularExpression.escapedPattern(for: text)
    }

    static func generateTeamAccountPassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var random = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in alphabet.randomElement(using: &random)! })
    }

    func resetTeamAccountPassword(req: Request) async throws -> ResetTeamAccountResponse {
        let body = try req.content.decode(ResetTeamAccountRequest.self)
        await TeamAccountGate.shared.acquire()
        do {
            let team = try await accountTeam(req)
            guard team.$user.id == body.expectedUserId else {
                throw Abort(.conflict, reason: "Die Zuordnung wurde geändert. Bitte neu laden.")
            }
            guard let user = try await User.find(body.expectedUserId, on: req.db), user.type == .team else {
                throw Abort(.badRequest, reason: "Kein Mannschaftsbenutzer zugeordnet.")
            }
            let password = Self.generateTeamAccountPassword()
            let previousHash = user.passwordHash
            user.passwordHash = try Bcrypt.hash(password)
            try await user.save(on: req.db)
            do {
                _ = try await EmailController().sendTeamAccountPassword(req: req, recipient: user.email, password: password).get()
            } catch {
                // Restore access when SMTP reports failure; never return or log the password.
                user.passwordHash = previousHash
                try await user.save(on: req.db)
                throw Abort(.badGateway, reason: "E-Mail konnte nicht versendet werden. Das bisherige Passwort bleibt gültig.")
            }
            var cleanupPending = false
            do {
                try await Token.query(on: req.db).filter(\.$user.$id == body.expectedUserId).delete()
                // Remove stale legacy plaintext copies for every team sharing this account.
                try await Team.query(on: req.db).filter(\.$user.$id == body.expectedUserId)
                    .set(\.$usrpass, to: nil).update()
            } catch {
                cleanupPending = true
                req.logger.error("Password reset cleanup failed for \(body.expectedUserId)")
            }
            await TeamAccountGate.shared.release()
            return ResetTeamAccountResponse(emailSent: true, cleanupPending: cleanupPending)
        } catch {
            await TeamAccountGate.shared.release()
            throw error
        }
    }

    private func accountTeam(_ req: Request) async throws -> Team {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        guard let team = try await Team.find(id, on: req.db) else { throw Abort(.notFound) }
        return team
    }

    private func accountResponse(userId: UUID?, db: Database) async throws -> TeamAccountResponse {
        guard let userId, let user = try await User.find(userId, on: db) else {
            return TeamAccountResponse(user: nil, teams: [])
        }
        let teams = try await Team.query(on: db).filter(\.$user.$id == userId).sort(\.$teamName).all()
        return TeamAccountResponse(user: try TeamAccountUser(user), teams: try teams.map {
            TeamAccountTeam(id: try $0.requireID(), name: $0.teamName, sid: $0.sid)
        })
    }
}
