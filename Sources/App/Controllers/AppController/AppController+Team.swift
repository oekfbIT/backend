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
    let image: String?
}

// MARK: - TEAM ENDPOINTS
extension AppController {
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
                    stats: nil
                )

                let awayOverview = AppModels.AppTeamOverview(
                    id: try away.requireID(),
                    sid: away.sid ?? "",
                    league: leagueOverview,
                    points: away.points,
                    logo: away.logo,
                    name: away.teamName,
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
            throw Abort(.badRequest, reason: "Trainer name is required when setting a trainer for the first time.")
        }

        let updatedCoach = Trainer(
            name: payload.name ?? existingCoach?.name ?? "Unbekannt",
            email: payload.email ?? existingCoach?.email,
            image: payload.image ?? existingCoach?.image
        )

        team.coach = updatedCoach

        try await team.save(on: req.db)
        return .ok
    }
}
