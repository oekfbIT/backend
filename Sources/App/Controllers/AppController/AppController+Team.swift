//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 09.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - AppController player & team endpoints
struct UpdateTrainerRequest: Content {
    let name: String?
    let email: String?
    let image: File?   // ⬅️ MUST be File for upload
}

// MARK: - TEAM ENDPOINTS
extension AppController {
    
    func setupTeamRoutes(on root: RoutesBuilder) {
        let team = root.grouped("team")

        team.get("sid", ":sid", use: getTeamBySID)
        team.get(":teamID", use: getTeamByID)
        team.get(":teamID", "fixtures", use: getFixturesByTeamID)
        team.get(":teamID", "balance", use: getTeamBalance)

        // Trainer (kept as-is but grouped neatly)
        let trainer = root.grouped("trainer")
        trainer.put(":teamID", use: updateTeamTrainer)
        trainer.get(":teamID", use: getTrainer)
        team.get(":teamID", "overdraft", use: setOverdraftLimit)
        team.get(":teamID", "overdraftInfo", use: getOverdraftInfo)

    }

    // MARK: - Overdraft Info DTO
    struct TeamOverdraftInfoResponse: Content {
        /// Can be nil (unknown/not set), false, or true depending on stored value
        let overdraft: Bool?
        /// Can be nil if not set
        let overdraftDate: Date?
    }

    // GET /app/team/:teamID/overdraftInfo
    func getOverdraftInfo(req: Request) async throws -> TeamOverdraftInfoResponse {
        let teamID = try req.parameters.require("teamID", as: UUID.self)

        guard let team = try await Team.find(teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        return TeamOverdraftInfoResponse(
            overdraft: team.overdraft,
            overdraftDate: team.overdraftDate
        )
    }

    // GET /app/team/:teamID
    func getTeamByID(req: Request) async throws -> AppModels.AppTeam {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID.")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$league)
            .with(\.$players)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        let leagueOverview = try team.league?.toAppLeagueOverview()
        ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await team.toAppTeamOverview(league: leagueOverview, req: req).get()

        let playerOverviews = try await team.players.asyncMap {
            try await $0.toAppPlayer(team: teamOverview, req: req)
        }
        
        return try await team.toAppTeam(league: leagueOverview, players: playerOverviews, req: req).get()
    }

    // MARK: - GET /app/team/:teamID/balance
    func getTeamBalance(req: Request) async throws -> Double {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID.")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == teamID)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        // normalize: return 0.0 if nil (or return nil if you prefer optional)
        return team.balance ?? 0.0
    }

    // GET /app/team/sid/:sid
    func getTeamBySID(req: Request) async throws -> AppModels.AppTeam {
        guard let sid = req.parameters.get("sid", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team SID.")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$sid == sid)
            .with(\.$league)
            .with(\.$players)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        let leagueOverview = try team.league?.toAppLeagueOverview()
        ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await team.toAppTeamOverview(league: leagueOverview, req: req).get()

        let playerOverviews = try await team.players.asyncMap {
            try await $0.toAppPlayer(team: teamOverview, req: req)
        }

        return try await team.toAppTeam(league: leagueOverview, players: playerOverviews, req: req).get()
    }
    
    func getFixturesByTeamID(req: Request) async throws -> [GameDayGroup] {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID.")
        }

        // 1️⃣ Load the team and its league
        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$league)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        guard let league = team.league else {
            throw Abort(.notFound, reason: "No league associated with this team.")
        }

        // Optional query parameter ?onlyPrimary=true
        let onlyPrimary = (try? req.query.get(Bool.self, at: "onlyPrimary")) ?? false

        // 2️⃣ Fetch relevant seasons
        var seasonQuery = Season.query(on: req.db)
            .filter(\.$league.$id == league.id)

        if onlyPrimary {
            seasonQuery = seasonQuery.filter(\.$primary == true)
        }

        let seasons = try await seasonQuery.all()
        let seasonIDs = try seasons.map { try $0.requireID() }

        // 3️⃣ Fetch matches where this team played (home or away)
        let matches = try await Match.query(on: req.db)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                or.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$season.$id ~~ seasonIDs)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        // 4️⃣ Group by gameday and sort by date
        let grouped = Dictionary(grouping: matches) { $0.details.gameday }
            .sorted { $0.key < $1.key }

        let leagueOverview = try league.toAppLeagueOverview()
        var groups: [GameDayGroup] = []

        for (day, matchesForDay) in grouped {
            let sortedMatches = matchesForDay.sorted {
                ($0.details.date ?? .distantPast) < ($1.details.date ?? .distantPast)
            }

            let appMatches: [AppModels.AppMatchOverview] = try await sortedMatches.asyncMap { match in
                let home = match.homeTeam
                let away = match.awayTeam

                let homeOverview = AppModels.AppTeamOverview(
                    id: try home.requireID(),
                    sid: home.sid ?? "",
                    league: leagueOverview,
                    points: home.points,
                    logo: home.logo,
                    name: home.teamName,
                    shortName: home.shortName,
                    stats: nil
                )

                let awayOverview = AppModels.AppTeamOverview(
                    id: try away.requireID(),
                    sid: away.sid ?? "",
                    league: leagueOverview,
                    points: away.points,
                    logo: away.logo,
                    name: away.teamName,
                    shortName: away.shortName,
                    stats: nil
                )

                let season = try match.season?.toAppSeason() ?? AppModels.AppSeason(
                    id: UUID().uuidString,
                    league: league.name,
                    leagueId: try league.requireID(),
                    name: "Primary"
                )

                return AppModels.AppMatchOverview(
                    id: try match.requireID(),
                    details: match.details,
                    score: match.score,
                    season: season,
                    away: awayOverview,
                    home: homeOverview,
                    homeBlanket: (match.homeBlanket ?? Blankett(
                        name: home.teamName,
                        dress: home.trikot.home,
                        logo: home.logo,
                        players: []
                    )).toMini(),
                    awayBlanket: (match.awayBlanket ?? Blankett(
                        name: away.teamName,
                        dress: away.trikot.away,
                        logo: away.logo,
                        players: []
                    )).toMini(),
                    status: match.status
                )
            }

            groups.append(GameDayGroup(gameday: day, matches: appMatches))
        }

        return groups
    }

    // PUT /app/team/:teamID/trainer
    func updateTeamTrainer(_ req: Request) async throws -> HTTPStatus {
        let teamID = try req.parameters.require("teamID", as: UUID.self)
        let payload = try req.content.decode(UpdateTrainerRequest.self)

        // If all optional fields are nil -> 400
        if payload.name == nil && payload.email == nil && payload.image == nil {
            throw Abort(.badRequest, reason: "No updatable fields provided.")
        }

        guard let team = try await Team.find(teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found")
        }

        let existingCoach = team.coach

        // If there is no existing coach and no name was provided,
        // we don't have a non-empty name for Trainer.name (non-optional).
        if existingCoach == nil && payload.name == nil {
            throw Abort(
                .badRequest,
                reason: "Trainer name is required when setting a trainer for the first time."
            )
        }

        // --- Firebase upload for trainer image (if a file was sent) ---

        var finalImageURL: String? = existingCoach?.image

        if let imageFile = payload.image, imageFile.data.readableBytes > 0 {
            let firebaseManager = req.application.firebaseManager

            // e.g. trainers/<teamUUID>/trainer_image
            let basePath = "trainers/\(teamID.uuidString)"
            let trainerImagePath = "\(basePath)/trainer_image"

            // authenticate & upload, get public download URL back
            try await firebaseManager.authenticate().get()
            let uploadedURL = try await firebaseManager
                .uploadFile(file: imageFile, to: trainerImagePath)
                .get()

            finalImageURL = uploadedURL
        }

        let updatedCoach = Trainer(
            name: payload.name ?? existingCoach?.name ?? "Unbekannt",
            email: payload.email ?? existingCoach?.email,
            image: finalImageURL
        )

        team.coach = updatedCoach

        try await team.save(on: req.db)
        return .ok
    }

    // GET /app/team/:teamID/trainer
    func getTrainer(req: Request) async throws -> Trainer {
        let teamID = try req.parameters.require("teamID", as: UUID.self)

        guard let team = try await Team.find(teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        guard let coach = team.coach else {
            throw Abort(.notFound, reason: "Trainer not set for this team.")
        }

        return coach
    }
    
    // GET /app/team/:teamID/overdraft
    func setOverdraftLimit(req: Request) async throws -> HTTPStatus {
        let teamID = try req.parameters.require("teamID", as: UUID.self)

        guard let team = try await Team.find(teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        // 1) balance must exist
        guard let balance = team.balance else {
            throw Abort(.badRequest, reason: "Team balance not available")
        }

        // 2) overdraft must not already be set
        guard team.overdraft == false else {
            throw Abort(.badRequest, reason: "Overdraft already set")
        }

        // 3) balance must be below 0
        guard balance < 0 else {
            throw Abort(.badRequest, reason: "Balance is non-negative; overdraft cannot be applied")
        }

        team.overdraft = true

        // 4) next Tuesday @ 12:00 Europe/Vienna (same logic as your original)
        let calendar = Calendar(identifier: .gregorian)
        let now = Date.viennaNow
        let weekday = calendar.component(.weekday, from: now)

        // Tuesday is 3 in Gregorian calendar where Sunday = 1
        let daysUntilTuesday = (3 - weekday + 7) % 7
        let nextTuesday = calendar.date(
            byAdding: .day,
            value: (daysUntilTuesday == 0 ? 7 : daysUntilTuesday),
            to: now
        )!

        var tuesdayComponents = calendar.dateComponents([.year, .month, .day], from: nextTuesday)
        tuesdayComponents.hour = 12
        tuesdayComponents.minute = 0
        tuesdayComponents.second = 0

        let overdraftDate = calendar.date(from: tuesdayComponents)!
        let viennaTimeZone = TimeZone(identifier: "Europe/Vienna")!
        let viennaOverdraftDate = overdraftDate.addingTimeInterval(
            TimeInterval(viennaTimeZone.secondsFromGMT(for: overdraftDate))
        )

        team.overdraftDate = viennaOverdraftDate

        // 5) create Rechnung + decrease balance
        let year = calendar.component(.year, from: Date.viennaNow)
        let randomFiveDigitNumber = String(format: "%05d", Int.random(in: 0..<100000))
        let invoiceNumber = "\(year)\(randomFiveDigitNumber)"

        let rechnungAmount: Double = 50.0

        let rechnung = Rechnung(
            team: team.id,
            teamName: team.teamName,
            number: invoiceNumber,
            summ: rechnungAmount,
            topay: nil,
            kennzeichen: "Overdraft"
        )

        try await rechnung.save(on: req.db)

        team.balance = balance - rechnungAmount
        try await team.save(on: req.db)

        return .ok
    }


}
