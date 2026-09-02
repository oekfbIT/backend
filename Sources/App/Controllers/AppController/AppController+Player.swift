//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 09.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - AppController player endpoints

struct UpdatePlayerRequest: Content {
    let email: String?
    let playerNumber: String?
}

extension AppController {
    func setupPlayerRoutes(on root: RoutesBuilder) {
        let player = root.grouped("player")

        player.get(":playerID", use: getPlayerByID)
        player.get("sid", ":sid", use: getPlayerBySID)
        player.put(":playerID", "email", use: updatePlayerEmailAddress)

        // Backwards-compatible alias used by older app versions.
        root.put(":playerID", "email", use: updatePlayerEmailAddress)

        // Team registration via app
        root.post("register", "team", use: registerTeamPlayer)
    }

    // GET /app/player/:playerID
    func getPlayerByID(req: Request) async throws -> AppModels.AppPlayer {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid player ID.")
        }

        let playerOptional = try await Player.query(on: req.db)
            .filter(\.$id == playerID)
            .with(\.$team) { $0.with(\.$league) }
            .with(\.$events)
            .first()

        guard let player = playerOptional else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        guard let teamModel = player.team else {
            throw Abort(.notFound, reason: "Team not found for this player.")
        }
        guard let league = teamModel.league else {
            throw Abort(.notFound, reason: "League not found for this player.")
        }

        // events → AppMatchEvent
        var appEvents: [AppModels.AppMatchEvent] = []
        for event in player.events {
            let appEvent = try await event.toAppMatchEvent(on: req)
            appEvents.append(appEvent)
        }

        let leagueOverview = try league.toAppLeagueOverview()

        let teamOverview = try await teamModel
            .toAppTeamOverview(league: leagueOverview, req: req)
            .get()

        // 0 or 1 next match, as array
        let nextMatches = try await teamModel.fetchNextAppNextMatches(on: req)
        let seasons = try await ClientController(path: "webClient")
            .seasonsForPlayerFast(player: player, league: league, req: req)
            .get()
        let stats = try await PlayerStatisticsService.calculate(
            playerID: playerID,
            activeLeagueID: league.id,
            on: req.db
        ).get()

        return try await player.toAppPlayer(
            team: teamOverview,
            events: appEvents,
            nextMatches: nextMatches,
            stats: stats.all,
            seasonStats: stats.season,
            matches: seasons,
            req: req
        )
    }

    // GET /app/player/sid/:sid
    func getPlayerBySID(req: Request) async throws -> AppModels.AppPlayer {
        guard let sid = req.parameters.get("sid", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid player SID.")
        }

        let playerOptional = try await Player.query(on: req.db)
            .filter(\.$sid == sid)
            .with(\.$team) { $0.with(\.$league) }
            .with(\.$events)
            .first()

        guard let player = playerOptional else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        guard let teamModel = player.team else {
            throw Abort(.notFound, reason: "Team not found for this player.")
        }
        guard let league = teamModel.league else {
            throw Abort(.notFound, reason: "League not found for this player.")
        }

        var appEvents: [AppModels.AppMatchEvent] = []
        for event in player.events {
            let appEvent = try await event.toAppMatchEvent(on: req)
            appEvents.append(appEvent)
        }

        let leagueOverview = try league.toAppLeagueOverview()

        let teamOverview = try await teamModel
            .toAppTeamOverview(league: leagueOverview, req: req)
            .get()

        let nextMatches = try await teamModel.fetchNextAppNextMatches(on: req)
        let playerID = try player.requireID()
        let seasons = try await ClientController(path: "webClient")
            .seasonsForPlayerFast(player: player, league: league, req: req)
            .get()
        let stats = try await PlayerStatisticsService.calculate(
            playerID: playerID,
            activeLeagueID: league.id,
            on: req.db
        ).get()

        return try await player.toAppPlayer(
            team: teamOverview,
            events: appEvents,
            nextMatches: nextMatches,
            stats: stats.all,
            seasonStats: stats.season,
            matches: seasons,
            req: req
        )
    }
    
    // PUT /app/player/:playerID/email
    func updatePlayerEmailAddress(_ req: Request) async throws -> HTTPStatus {
        let playerID = try req.parameters.require("playerID", as: UUID.self)
        let payload = try req.content.decode(UpdatePlayerRequest.self)

        // if both are nil -> 400
        if payload.email == nil && payload.playerNumber == nil {
            throw Abort(.badRequest, reason: "No updatable fields provided.")
        }

        guard let player = try await Player.find(playerID, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found")
        }

        if let newEmail = payload.email {
            player.email = newEmail
        }

        if let newNumber = payload.playerNumber {
            player.number = newNumber
        }

        try await player.save(on: req.db)
        return .ok // 200, empty body
    }

}
