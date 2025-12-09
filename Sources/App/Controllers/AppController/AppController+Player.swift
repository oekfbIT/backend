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

        let limitedEvents = player.events.prefix(100)

        // events → AppMatchEvent
        var appEvents: [AppModels.AppMatchEvent] = []
        for event in player.events {
            let appEvent = try await event.toAppMatchEvent(on: req)
            appEvents.append(appEvent)
        }

        let leagueOverview = try teamModel.league?.toAppLeagueOverview()
            ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await teamModel
            .toAppTeamOverview(league: leagueOverview, req: req)
            .get()

        // 0 or 1 next match, as array
        let nextMatches = try await teamModel.fetchNextAppNextMatches(on: req)

        return try await player.toAppPlayer(
            team: teamOverview,
            events: appEvents,
            nextMatches: nextMatches,
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

        let limitedEvents = player.events.prefix(100)

        var appEvents: [AppModels.AppMatchEvent] = []
        for event in player.events {
            let appEvent = try await event.toAppMatchEvent(on: req)
            appEvents.append(appEvent)
        }

        let leagueOverview = try teamModel.league?.toAppLeagueOverview()
            ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await teamModel
            .toAppTeamOverview(league: leagueOverview, req: req)
            .get()

        let nextMatches = try await teamModel.fetchNextAppNextMatches(on: req)

        return try await player.toAppPlayer(
            team: teamOverview,
            events: appEvents,
            nextMatches: nextMatches,
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
