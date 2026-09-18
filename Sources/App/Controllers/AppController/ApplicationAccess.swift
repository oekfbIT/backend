import Fluent
import Vapor

/// Shared ownership checks for authenticated application routes. Admin users may
/// access every record; all other users are limited to teams assigned to their
/// account and records belonging to those teams.
enum ApplicationAccess {
    static func authorize(team: Team, req: Request) throws {
        let user = try req.auth.require(User.self)
        guard user.type == .admin || team.$user.id == user.id else {
            throw Abort(.forbidden, reason: "This team does not belong to your account.")
        }
    }

    @discardableResult
    static func requireTeam(_ id: UUID, req: Request) async throws -> Team {
        guard let team = try await Team.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found.")
        }
        try authorize(team: team, req: req)
        return team
    }

    @discardableResult
    static func requirePlayer(_ id: UUID, req: Request) async throws -> Player {
        guard let player = try await Player.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }
        guard let teamID = player.$team.id else {
            throw Abort(.forbidden, reason: "Player has no owning team.")
        }
        _ = try await requireTeam(teamID, req: req)
        return player
    }
}

struct TeamParameterAccessMiddleware: AsyncMiddleware {
    let parameter: String

    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let id = try req.parameters.require(parameter, as: UUID.self)
        _ = try await ApplicationAccess.requireTeam(id, req: req)
        return try await next.respond(to: req)
    }
}

struct PlayerParameterAccessMiddleware: AsyncMiddleware {
    let parameter: String

    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let id = try req.parameters.require(parameter, as: UUID.self)
        _ = try await ApplicationAccess.requirePlayer(id, req: req)
        return try await next.respond(to: req)
    }
}

struct ConversationParameterAccessMiddleware: AsyncMiddleware {
    let parameter: String

    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let id = try req.parameters.require(parameter, as: UUID.self)
        guard let conversation = try await Conversation.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Conversation not found.")
        }
        guard let teamID = conversation.$team.id else {
            throw Abort(.forbidden, reason: "Conversation has no owning team.")
        }
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)
        return try await next.respond(to: req)
    }
}

struct MatchAccessMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let user = try req.auth.require(User.self)
        if user.type == .admin {
            return try await next.respond(to: req)
        }

        let matchID = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchID, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found.")
        }
        let userID = try user.requireID()

        let ownsParticipatingTeam = try await Team.query(on: req.db)
            .filter(\.$id ~~ [match.$homeTeam.id, match.$awayTeam.id])
            .filter(\.$user.$id == userID)
            .count() > 0

        let isAssignedReferee: Bool
        if let refereeID = match.$referee.id,
           let referee = try await Referee.find(refereeID, on: req.db) {
            isAssignedReferee = referee.$user.id == userID
        } else {
            isAssignedReferee = false
        }

        guard ownsParticipatingTeam || isAssignedReferee else {
            throw Abort(.forbidden, reason: "You are not assigned to this match.")
        }
        return try await next.respond(to: req)
    }
}
