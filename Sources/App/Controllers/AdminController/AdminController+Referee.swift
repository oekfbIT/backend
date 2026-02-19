import Foundation
import Vapor
import Fluent

// MARK: - Admin Referee Routes
extension AdminController {

    /// Mounted under /admin/referees/...
    func setupRefereeRoutes(on root: RoutesBuilder) {
        let refs = root.grouped("referees")

        // GET /admin/referees
        refs.get(use: getAllReferees)

        // GET /admin/referees/compact
        refs.get("compact", use: getAllRefereesCompact)

        // GET /admin/referees/:id
        refs.get(":id", use: getRefereeByID)

        // PATCH /admin/referees/:id
        refs.patch(":id", use: patchReferee)

        // GET /admin/referees/:id/bundle
        refs.get(":id", "bundle", use: getRefereeBundleByID)

        refs.post(":id", "topup", use: topupRefereeBalance)

    }
}

// MARK: - DTOs
extension AdminController {

    struct TopupRefereeRequest: Content {
        let amount: Double
    }
    
    struct AdminRefereeCompact: Content {
        let id: UUID
        let name: String?
        let image: String?
        let phone: String?
        let nationality: String?
        let balance: Double?
    }

    struct PatchRefereeRequest: Content {
        let balance: Double?
        let name: String?
        let phone: String?
        let identification: String?
        let image: String?
        let nationality: String?
        let userId: UUID?
    }

    struct RefereeAssignmentCompact: Content {
        let id: UUID
        let date: Date?
        let stadium: UUID?
        let location: String?
        let homeTeamName: String
        let awayTeamName: String
        let homeTeamLogo: String?
        let awayTeamLogo: String?
        let paid: Bool?
    }

    struct RefereeBundle: Content {
        let referee: Referee
        let assignments: [RefereeAssignmentCompact]   // only unpaid
    }
}

// MARK: - Handlers
extension AdminController {

    // GET /admin/referees
    func getAllReferees(req: Request) async throws -> [Referee] {
        try await Referee.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()
    }

    // GET /admin/referees/:id
    func getRefereeByID(req: Request) async throws -> Referee {
        let ref = try await requireReferee(req: req, param: "id")
        return ref
    }

    // PATCH /admin/referees/:id
    func patchReferee(req: Request) async throws -> Referee {
        let ref = try await requireReferee(req: req, param: "id")
        let body = try req.content.decode(PatchRefereeRequest.self)

        // minimal patch semantics
        if let v = body.balance { ref.balance = v }
        if let v = body.name { ref.name = v }
        if let v = body.phone { ref.phone = v }
        if let v = body.identification { ref.identification = v }
        if let v = body.image { ref.image = v }
        if let v = body.nationality { ref.nationality = v }
        if let v = body.userId { ref.$user.id = v }

        try await ref.save(on: req.db)
        return ref
    }

    // GET /admin/referees/compact
    func getAllRefereesCompact(req: Request) async throws -> [AdminRefereeCompact] {
        let refs = try await Referee.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()

        return try refs.map { r in
            AdminRefereeCompact(
                id: try r.requireID(),
                name: r.name,
                image: r.image,
                phone: r.phone,
                nationality: r.nationality,
                balance: r.balance
            )
        }
    }

    // GET /admin/referees/:id/bundle
    // -> referee + assignments where paid != true
    func getRefereeBundleByID(req: Request) async throws -> RefereeBundle {
        let ref = try await requireReferee(req: req, param: "id")
        let refId = try ref.requireID()

        // only matches assigned to this referee and not paid
        let matches = try await Match.query(on: req.db)
            .filter(\.$referee.$id == refId)
            .group(.or) { g in
                g.filter(\.$paid == false)
                g.filter(\.$paid == nil) // treat nil as unpaid
            }
            .with(\.$homeTeam)
            .with(\.$awayTeam)
//            .sort(\.$details.$date, .descending) // uses your FieldKey "details.date" alias
            .all()

        let assignments: [RefereeAssignmentCompact] = try matches.map { m in
            RefereeAssignmentCompact(
                id: try m.requireID(),
                date: m.details.date,
                stadium: m.details.stadium,
                location: m.details.location,
                homeTeamName: m.homeTeam.teamName,
                awayTeamName: m.awayTeam.teamName,
                homeTeamLogo: m.homeTeam.logo,
                awayTeamLogo: m.awayTeam.logo,
                paid: m.paid
            )
        }

        return RefereeBundle(referee: ref, assignments: assignments)
    }
    
    // POST /admin/referees/:id/topup
        func topupRefereeBalance(req: Request) async throws -> HTTPStatus {
            guard let refereeId = req.parameters.get("id", as: UUID.self) else {
                throw Abort(.badRequest, reason: "Missing or invalid referee ID.")
            }

            let body = try req.content.decode(TopupRefereeRequest.self)
            guard body.amount > 0 else {
                throw Abort(.badRequest, reason: "amount must be > 0.")
            }

            guard let referee = try await Referee.find(refereeId, on: req.db) else {
                throw Abort(.notFound, reason: "Referee not found.")
            }

            referee.balance = (referee.balance ?? 0) + body.amount
            try await referee.save(on: req.db)
            return .ok
        }
}

// MARK: - Helpers
private extension AdminController {
    func requireReferee(req: Request, param: String) async throws -> Referee {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid referee ID.")
        }
        guard let ref = try await Referee.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Referee not found.")
        }
        return ref
    }
}
