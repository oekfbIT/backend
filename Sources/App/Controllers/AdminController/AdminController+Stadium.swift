//
//  AdminController+StadiumRoutes.swift
//
//  Admin Stadium Routes (pattern-matched to your other AdminController extensions)
//
//  Endpoints:
//  - GET    /admin/stadiums                          -> [Stadium]
//  - GET    /admin/stadiums/:id                      -> Stadium
//  - PATCH  /admin/stadiums/:id                      -> Stadium          (multipart; optional image upload)
//  - GET    /admin/stadiums/:id/matches              -> [AdminMatchCompact]
//  - GET    /admin/stadiums/:id/matches/open         -> [AdminMatchCompact] (status != .done)
//
//  Notes:
//  - PATCH accepts multipart/form-data (Content) with optional File `image`.
//  - If image is present, uploads to Firebase and sets Stadium.image to returned URL.
//  - For optional fields that may be cleared, send empty string "" and we interpret as nil.
//  - Stadium matching assumes Match.details.stadium contains the stadium UUID.
//  - Compact match includes team names + logos (from Team model).
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Stadium Routes
extension AdminController {

    func setupStadiumRoutes(on root: RoutesBuilder) {
        let stadiums = root.grouped("stadiums")

        stadiums.get(use: getAllStadiums)
        stadiums.get(":id", use: getStadiumByID)

        // multipart patch (optional image)
        stadiums.patch(":id", use: patchStadium)

        // matches
        stadiums.get(":id", "matches", use: getMatchesForStadium)
        stadiums.get(":id", "matches", "open", use: getOpenMatchesForStadium)
    }
}

// MARK: - DTOs
extension AdminController {

    /// Multipart patch payload.
    /// - Any field omitted remains unchanged.
    /// - For optional string/number fields: send "" to clear (becomes nil).
    struct PatchStadiumRequest: Content {
        var bundesland: Bundesland?
        var code: String?
        var name: String?
        var address: String?

        var type: String?
        var schuhwerk: String?
        var flutlicht: Bool?
        var parking: Bool?

        var homeTeam: String?
        var partnerSince: String?

        var lat: Double?
        var lon: Double?

        var image: File?
    }

    struct AdminMatchCompact: Content {
        let id: UUID

        let gameday: Int
        let date: Date?
        let location: String?

        let stadiumId: UUID?

        let status: GameStatus
        let paid: Bool?

        let homeTeamName: String
        let homeTeamLogo: String?

        let awayTeamName: String
        let awayTeamLogo: String?
    }
}

// MARK: - Handlers
extension AdminController {

    // GET /admin/stadiums
    func getAllStadiums(req: Request) async throws -> [Stadium] {
        try await Stadium.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()
    }

    // GET /admin/stadiums/:id
    func getStadiumByID(req: Request) async throws -> Stadium {
        let stadium = try await requireStadium(req: req, param: "id")
        return stadium
    }

    // PATCH /admin/stadiums/:id   (multipart/form-data)
    func patchStadium(req: Request) async throws -> Stadium {
        let stadium = try await requireStadium(req: req, param: "id")
        let body = try req.content.decode(PatchStadiumRequest.self)

        // --- apply simple fields (trim where needed) ---
        if let v = body.bundesland { stadium.bundesland = v }

        if let v = body.code {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "code cannot be empty.") }
            stadium.code = t
        }

        if let v = body.name {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "name cannot be empty.") }
            stadium.name = t
        }

        if let v = body.address {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "address cannot be empty.") }
            stadium.address = t
        }

        if let v = body.type { stadium.type = v }
        if let v = body.schuhwerk { stadium.schuhwerk = v }
        if let v = body.flutlicht { stadium.flutlicht = v }
        if let v = body.parking { stadium.parking = v }

        if let v = body.homeTeam {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            stadium.homeTeam = t.isEmpty ? nil : t
        }

        if let v = body.partnerSince {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            stadium.partnerSince = t.isEmpty ? nil : t
        }

        if body.lat != nil { stadium.lat = body.lat }
        if body.lon != nil { stadium.lon = body.lon }

        // --- optional image upload ---
        if let img = body.image, img.data.readableBytes > 0 {
            let firebaseManager = req.application.firebaseManager
            try await firebaseManager.authenticate().get()

            let stadiumId = try stadium.requireID()
            let path = "stadiums/\(stadiumId.uuidString)/image"
            let url = try await firebaseManager.uploadFile(file: img, to: path).get()
            stadium.image = url
        }

        try await stadium.save(on: req.db)
        return stadium
    }

    // GET /admin/stadiums/:id/matches
    func getMatchesForStadium(req: Request) async throws -> [AdminMatchCompact] {
        let stadium = try await requireStadium(req: req, param: "id")
        let stadiumId = try stadium.requireID()

        // Load matches, then filter in-memory by details.stadium
        // (because details is JSON; querying inside JSON is DB-dependent)
        let matches = try await Match.query(on: req.db)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        let filtered = matches.filter { $0.details.stadium == stadiumId }

        // Sort by date asc (nil last)
        let sorted = filtered.sorted {
            let d1 = $0.details.date ?? .distantFuture
            let d2 = $1.details.date ?? .distantFuture
            return d1 < d2
        }

        return try sorted.map { m in
            AdminMatchCompact(
                id: try m.requireID(),
                gameday: m.details.gameday,
                date: m.details.date,
                location: m.details.location,
                stadiumId: m.details.stadium,
                status: m.status,
                paid: m.paid,
                homeTeamName: m.homeTeam.teamName,
                homeTeamLogo: m.homeTeam.logo,
                awayTeamName: m.awayTeam.teamName,
                awayTeamLogo: m.awayTeam.logo
            )
        }
    }

    // GET /admin/stadiums/:id/matches/open   (not done)
    func getOpenMatchesForStadium(req: Request) async throws -> [AdminMatchCompact] {
        let all = try await getMatchesForStadium(req: req)
        // keep anything that isn't done
        return all.filter { $0.status != .done }
    }
}

// MARK: - Helpers
private extension AdminController {
    func requireStadium(req: Request, param: String) async throws -> Stadium {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid stadium ID.")
        }
        guard let stadium = try await Stadium.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Stadium not found.")
        }
        return stadium
    }
}
