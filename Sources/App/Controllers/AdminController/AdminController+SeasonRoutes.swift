//
//  AdminController+SeasonRoutes.swift
//  oekfbbackend
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Season Routes
extension AdminController {

    func setupSeasonRoutes(on root: RoutesBuilder) {
        let seasons = root.grouped("seasons")

        // GET /admin/seasons/:id
        seasons.get(":id", use: getSeasonByID)

        // GET /admin/seasons/:id/bundle
        seasons.get(":id", "bundle", use: getSeasonBundle)

        // GET /admin/seasons/:id/gameday
        seasons.get(":id", "gameday", use: getCurrentGameday)

        // POST /admin/seasons/:id/gameday/matches
        seasons.post(":id", "gameday", "matches", use: getMatchesForGameday)

        // PATCH /admin/seasons/:id
        seasons.patch(":id", use: patchSeason)

        // PATCH /admin/seasons/:id/matches/:matchId/referee
        seasons.patch(":id", "matches", ":matchId", "referee", use: patchMatchReferee)

        // PATCH /admin/seasons/:id/matches/:matchId/time
        seasons.patch(":id", "matches", ":matchId", "time", use: patchMatchTime)

        // PATCH /admin/seasons/:id/matches/:matchId/location
        seasons.patch(":id", "matches", ":matchId", "location", use: patchMatchLocation)
        
        seasons.post(":id", "gameday", "complete", use: completeGameday)

    }
}

// MARK: - DTOs
extension AdminController {

    // ✅ Lightweight referee DTO to avoid encoding @Children assignments
    struct AdminRefereeOverview: Content {
        let id: UUID
        let userId: UUID?
        let balance: Double?
        let name: String?
        let phone: String?
        let identification: String?
        let image: String?
        let nationality: String?
    }

    // ✅ Bundle response now includes referees + stadiums
    struct SeasonBundleResponse: Content {
        let season: Season
        let gameday: Int
        let gamedays: [Int]
        let matches: [Match]
        let referees: [AdminRefereeOverview]
        let stadiums: [Stadium]
    }

    struct PatchSeasonRequest: Content {
        let name: String?
        let details: Int?
        let primary: Bool?
        let table: SeasonTable?
        let winner: UUID?
        let runnerup: UUID?
        let gameday: Int?
        let leagueId: UUID?
    }

    struct MatchesForGamedayRequest: Content {
        let gameday: Int
    }

    struct PatchMatchRefereeRequest: Content {
        let refereeId: UUID?
    }

    struct PatchMatchTimeRequest: Content {
        let date: Date?
    }

    struct PatchMatchLocationRequest: Content {
        let stadiumId: UUID?
        let location: String?
    }
}

// MARK: - Handlers
extension AdminController {

    func getSeasonByID(req: Request) async throws -> Season {
        try await requireSeason(req: req, param: "id")
    }

    /// ✅ GET /admin/seasons/:id/bundle
    /// Uses Season.gameday (no body, no query params)
    /// Returns Season + matches for that gameday + all referees + all stadiums
    func getSeasonBundle(req: Request) async throws -> SeasonBundleResponse {
        let season = try await requireSeason(req: req, param: "id")
        let seasonId = try season.requireID()
        let gd = season.gameday ?? 0

        guard gd >= 0 else {
            throw Abort(.badRequest, reason: "Season.gameday must be >= 0.")
        }

        let allMatches = try await Match.query(on: req.db)
            .filter(\.$season.$id == seasonId)
            .all()

        let gamedays: [Int] = Array(
            Set(allMatches.map { $0.details.gameday })
        ).sorted()

        // Matches for the season’s current gameday
        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id == seasonId)
            .filter(Match.FieldKeys.gameday, .equal, gd) // FieldKey JSON filter
            .sort(Match.FieldKeys.date, .ascending)
            .all()

        // All referees (map to DTO to avoid encoding children)
        let refereeModels = try await Referee.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()

        let referees: [AdminRefereeOverview] = try refereeModels.map { r in
            AdminRefereeOverview(
                id: try r.requireID(),
                userId: r.$user.id,
                balance: r.balance,
                name: r.name,
                phone: r.phone,
                identification: r.identification,
                image: r.image,
                nationality: r.nationality
            )
        }

        // All stadiums
        let stadiums = try await Stadium.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()

        return SeasonBundleResponse(
            season: season,
            gameday: gd,
            gamedays: gamedays,
            matches: matches,
            referees: referees,
            stadiums: stadiums
        )
    }

    func getCurrentGameday(req: Request) async throws -> Int {
        let season = try await requireSeason(req: req, param: "id")
        return season.gameday ?? 0
    }

    func getMatchesForGameday(req: Request) async throws -> [Match] {
        let season = try await requireSeason(req: req, param: "id")
        let seasonId = try season.requireID()
        let body = try req.content.decode(MatchesForGamedayRequest.self)

        guard body.gameday >= 0 else {
            throw Abort(.badRequest, reason: "gameday must be >= 0.")
        }

        return try await Match.query(on: req.db)
            .filter(\.$season.$id == seasonId)
            .filter(Match.FieldKeys.gameday, .equal, body.gameday)
            .sort(Match.FieldKeys.date, .ascending)
            .all()
    }

    func patchSeason(req: Request) async throws -> Season {
        let season = try await requireSeason(req: req, param: "id")
        let patch = try req.content.decode(PatchSeasonRequest.self)

        if let leagueId = patch.leagueId { season.$league.id = leagueId }

        if let name = patch.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "Season name cannot be empty.")
            }
            season.name = trimmed
        }

        if let details = patch.details { season.details = details }
        if let primary = patch.primary { season.primary = primary }
        if let table = patch.table { season.table = table }
        if let winner = patch.winner { season.winner = winner }
        if let runnerup = patch.runnerup { season.runnerup = runnerup }

        if let gameday = patch.gameday {
            guard gameday >= 0 else {
                throw Abort(.badRequest, reason: "gameday must be >= 0.")
            }
            season.gameday = gameday
        }

        try await season.save(on: req.db)
        return season
    }

    func patchMatchReferee(req: Request) async throws -> Match {
        let (_, match) = try await requireSeasonAndMatch(req: req)
        let body = try req.content.decode(PatchMatchRefereeRequest.self)

        if let refId = body.refereeId {
            guard let _ = try await Referee.find(refId, on: req.db) else {
                throw Abort(.notFound, reason: "Referee not found.")
            }
            match.$referee.id = refId
        } else {
            match.$referee.id = nil
        }

        try await match.save(on: req.db)
        return match
    }

    func patchMatchTime(req: Request) async throws -> Match {
        let (_, match) = try await requireSeasonAndMatch(req: req)
        let body = try req.content.decode(PatchMatchTimeRequest.self)

        var details = match.details
        details.date = body.date
        match.details = details

        try await match.save(on: req.db)
        return match
    }

    func patchMatchLocation(req: Request) async throws -> Match {
        let (_, match) = try await requireSeasonAndMatch(req: req)
        let body = try req.content.decode(PatchMatchLocationRequest.self)

        if let stadiumId = body.stadiumId {
            guard let _ = try await Stadium.find(stadiumId, on: req.db) else {
                throw Abort(.notFound, reason: "Stadium not found.")
            }
        }

        var details = match.details
        details.stadium = body.stadiumId

        if let location = body.location {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            details.location = trimmed.isEmpty ? nil : trimmed
        }

        match.details = details

        try await match.save(on: req.db)
        return match
    }
    
    // MARK: POST /admin/seasons/:id/gameday/complete
    /// Increments season.gameday by 1 unless it is already the max available gameday.
    func completeGameday(req: Request) async throws -> Int {
        let season = try await requireSeason(req: req, param: "id")
        let seasonId = try season.requireID()

        // Collect all unique gamedays available in this season (from matches)
        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id == seasonId)
            .all()

        let gamedays = Array(Set(matches.map { $0.details.gameday })).sorted()
        let maxGameday = gamedays.last ?? 0

        let current = season.gameday ?? 0
        let next = min(current + 1, maxGameday)

        season.gameday = next
        try await season.save(on: req.db)

        return next
    }

}

// MARK: - Helpers
private extension AdminController {

    func requireSeason(req: Request, param: String) async throws -> Season {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid season ID.")
        }
        guard let season = try await Season.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Season not found.")
        }
        return season
    }

    func requireSeasonAndMatch(req: Request) async throws -> (Season, Match) {
        let season = try await requireSeason(req: req, param: "id")
        let seasonId = try season.requireID()

        guard let matchId = req.parameters.get("matchId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid match ID.")
        }
        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found.")
        }

        guard match.$season.id == seasonId else {
            throw Abort(.badRequest, reason: "Match does not belong to this season.")
        }

        return (season, match)
    }
}
