import Fluent
import Vapor

extension AppController {
    /// Data required by the referee web application. This intentionally omits
    /// identification documents, phone numbers and the linked user record.
    struct RefereeSelfResponse: Content {
        let id: UUID
        let name: String?
        let image: String?
        let nationality: String?
        let balance: Double
        let assignments: [AppModels.AppMatchOverview]
    }

    func setupRefereeRoutes(on route: RoutesBuilder) {
        route.group("referee") { referee in
            referee.get("me", use: getCurrentReferee)
        }
    }

    /// GET /app/referee/me
    /// Resolves the referee from the authenticated user instead of accepting a
    /// caller-controlled referee id, preventing horizontal account access.
    func getCurrentReferee(req: Request) async throws -> RefereeSelfResponse {
        let user = try req.auth.require(User.self)
        guard user.type == .referee else {
            throw Abort(.forbidden, reason: "Referee access required.")
        }

        let userID = try user.requireID()
        guard let referee = try await Referee.query(on: req.db)
            .filter(Referee.FieldKeys.userId, .equal, userID)
            .first(),
              let refereeID = referee.id
        else {
            throw Abort(.notFound, reason: "Referee profile not found.")
        }

        let matches = try await Match.query(on: req.db)
            .filter(Match.FieldKeys.referee, .equal, refereeID)
            .all()
        let lookup = try await buildMatchLookup(matches: matches, on: req.db)

        var assignments: [AppModels.AppMatchOverview] = []
        assignments.reserveCapacity(matches.count)
        for match in matches {
            if let assignment = try await toAppMatchOverviewSafe(match: match, lookup: lookup, req: req) {
                assignments.append(assignment)
            }
        }
        assignments.sort {
            ($0.details.date ?? .distantFuture) < ($1.details.date ?? .distantFuture)
        }

        return RefereeSelfResponse(
            id: refereeID,
            name: referee.name,
            image: referee.image,
            nationality: referee.nationality,
            balance: referee.balance ?? 0,
            assignments: assignments
        )
    }
}
