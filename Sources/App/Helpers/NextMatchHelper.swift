//
//  NextMatchHelpers.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 27.11.25.
//

import Foundation 
import Fluent
import Vapor

// MARK: - API Models

extension AppModels {
    struct NextMatch: Content, Codable {
        let match: AppMatchOverview
    }
}

// MARK: - Team helpers

extension Team {

    // ============================================================
    // VERSION A — ACTIVE VERSION
    // "Next pending match" regardless of date (even if in the past)
    // ============================================================
    func fetchNextMatchForPrimarySeasons(on db: Database) async throws -> Match? {
        guard let leagueID = self.$league.id else { return nil }
        let teamID = try requireID()

        // 1️⃣ pending matches where this team plays
        var query = Match.query(on: db)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                or.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status == .pending)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$season) { $0.with(\.$league) }

        // 2️⃣ Only primary seasons of this league
        query = query
            .join(parent: \Match.$season)
            .filter(Season.self, \.$league.$id == leagueID)
            .filter(Season.self, \.$primary == true)

        let matches = try await query.all()
        guard !matches.isEmpty else { return nil }

        // 3️⃣ Pick earliest by gameday → then by date (nil = far future)
        return matches.min { lhs, rhs in
            if lhs.details.gameday == rhs.details.gameday {
                let ld = lhs.details.date ?? .distantFuture
                let rd = rhs.details.date ?? .distantFuture
                return ld < rd
            } else {
                return lhs.details.gameday < rhs.details.gameday
            }
        }
    }



    // ======================================================================
    // VERSION B — OPTIONAL ALTERNATIVE (COMMENTED OUT)
    // Only pick pending matches where the date is in the future.
    // Uncomment if you ever want "next match" based strictly on date >= now.
    // ======================================================================

    /*
    func fetchNextMatchForPrimarySeasons(on db: Database) async throws -> Match? {
        guard let leagueID = self.$league.id else { return nil }
        let teamID = try requireID()
        let now = Date()

        var query = Match.query(on: db)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                or.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status == .pending)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$season) { $0.with(\.$league) }

        query = query
            .join(parent: \Match.$season)
            .filter(Season.self, \.$league.$id == leagueID)
            .filter(Season.self, \.$primary == true)

        let matches = try await query.all()

        // only future-dated matches
        let futureMatches = matches.filter { match in
            guard let date = match.details.date else { return false }
            return date >= now
        }

        guard !futureMatches.isEmpty else { return nil }

        // earliest date wins
        return futureMatches.min { lhs, rhs in
            let ld = lhs.details.date ?? .distantFuture
            let rd = rhs.details.date ?? .distantFuture
            return ld < rd
        }
    }
    */

}

// MARK: - Team helpers

extension Team {

    /// Single `NextMatch` model, or `nil` if none.
    func fetchNextAppNextMatch(on req: Request) async throws -> AppModels.NextMatch? {
        guard let rawMatch = try await fetchNextMatchForPrimarySeasons(on: req.db) else {
            return nil
        }

        // League / season
        let season = rawMatch.season
        let league = season?.league ?? self.league
        guard let leagueResolved = league else { return nil }

        let leagueOverview = try leagueResolved.toAppLeagueOverview()
        let seasonOverview = try season?.toAppSeason() ?? AppModels.AppSeason(
            id: UUID().uuidString,
            league: leagueResolved.name,
            leagueId: try leagueResolved.requireID(),
            name: "Primary"
        )

        let home = rawMatch.homeTeam
        let away = rawMatch.awayTeam

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

        let overview = AppModels.AppMatchOverview(
            id: try rawMatch.requireID(),
            details: rawMatch.details,
            score: rawMatch.score,
            season: seasonOverview,
            away: awayOverview,
            home: homeOverview,
            homeBlanket: (rawMatch.homeBlanket ?? Blankett(
                name: home.teamName,
                dress: home.trikot.home,
                logo: home.logo,
                players: []
            )).toMini(),
            awayBlanket: (rawMatch.awayBlanket ?? Blankett(
                name: away.teamName,
                dress: away.trikot.away,
                logo: away.logo,
                players: []
            )).toMini(),
            status: rawMatch.status
        )

        return AppModels.NextMatch(match: overview)
    }

    /// Always returns an array (0 or 1 element).
    func fetchNextAppNextMatches(on req: Request) async throws -> [AppModels.NextMatch] {
        if let single = try await fetchNextAppNextMatch(on: req) {
            return [single]
        } else {
            return []
        }
    }
}

// MARK: - AppController player endpoints

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
}
