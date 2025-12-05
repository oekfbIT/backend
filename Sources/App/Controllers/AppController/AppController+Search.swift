//
//  AppController+Search.swift
//

import Foundation
import Vapor
import Fluent
import FluentMongoDriver

// MARK: - DTOs

struct AppSearchResults: Content {
    let players: [AppModels.AppPlayerOverview]
    let playersCount: Int

    let teams: [AppModels.AppTeamOverview]
    let teamsCount: Int

    let leagues: [AppModels.AppLeagueOverview]
    let leaguesCount: Int
}

struct AppSearchRequest: Content {
    let query: String
}

// MARK: - Mongo Regex Helper
//
// This follows the example from Vapor docs:
//
//   import FluentMongoDriver
//   var queryDocument = Document()
//   queryDocument["name"]["$regex"] = "e"
//   queryDocument["name"]["$options"] = "i"
//   Planet.query(on: req.db).filter(.custom(queryDocument)).all()
//
// We wrap that into a small helper on QueryBuilder so we can write:
//   Team.query(on: db).mongoRegex("teamName", pattern).all()

extension QueryBuilder {
    /// Case-insensitive MongoDB regex filter on a given field.
    /// - Parameters:
    ///   - field: The raw Mongo field name (e.g. `"teamName"`, `"name"`).
    ///   - pattern: The regex pattern. We pass `"i"` option for case-insensitive search.
    func mongoRegex(_ field: String, _ pattern: String) -> Self {
        var queryDocument = Document()
        queryDocument[field]["$regex"] = pattern
        queryDocument[field]["$options"] = "i" // case-insensitive
        return self.filter(.custom(queryDocument))
    }
}

// MARK: - SEARCH ROUTES

extension AppController {

    /// Register search route:
    /// POST /app/search
    ///
    /// Body:
    /// {
    ///   "query": "Bida"
    /// }
    func setupSearchRoutes(on route: RoutesBuilder) throws {
        route.post("search", use: search)
    }

    /// POST /app/search
    ///
    /// - Decodes `AppSearchRequest`
    /// - Runs three parallel Mongo regex queries against:
    ///   * League.name
    ///   * Team.teamName
    ///   * Player.name
    /// - Each collection:
    ///   * Returns at most 10 items
    ///   * Also returns the *total* count (before limiting) for UI paging / “show more”
    ///
    /// Result JSON:
    /// {
    ///   "players": [...],
    ///   "playersCount": 12,
    ///   "teams": [...],
    ///   "teamsCount": 3,
    ///   "leagues": [...],
    ///   "leaguesCount": 1
    /// }
    func search(req: Request) async throws -> AppSearchResults {
        let payload = try req.content.decode(AppSearchRequest.self)
        let rawQuery = payload.query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard rawQuery.isEmpty == false else {
            throw Abort(.badRequest, reason: "Query cannot be empty.")
        }

        // Escape user input so it is treated as literal text inside regex.
        // The `"i"` option in `mongoRegex` will make it case-insensitive.
        let pattern = NSRegularExpression.escapedPattern(for: rawQuery)

        // --------------------------------------------------------------
        // LEAGUES
        // --------------------------------------------------------------
        async let leaguesCountFuture = League.query(on: req.db)
            .mongoRegex("name", pattern)
            .count()

        async let leagueModelsFuture = League.query(on: req.db)
            .mongoRegex("name", pattern)
            .limit(10)
            .all()

        // --------------------------------------------------------------
        // TEAMS
        // --------------------------------------------------------------
        async let teamsCountFuture = Team.query(on: req.db)
            .mongoRegex("teamName", pattern)
            .count()

        async let teamModelsFuture = Team.query(on: req.db)
            .with(\.$league)
            .mongoRegex("teamName", pattern)
            .limit(10)
            .all()

        // --------------------------------------------------------------
        // PLAYERS
        // --------------------------------------------------------------
        async let playersCountFuture = Player.query(on: req.db)
            .mongoRegex("name", pattern)
            .count()

        async let playerModelsFuture = Player.query(on: req.db)
            .with(\.$team) { team in
                team.with(\.$league)
            }
            .mongoRegex("name", pattern)
            .limit(20)
            .all()

        // Wait for all six async operations
        let (
            leaguesTotal,
            leagueModels,
            teamsTotal,
            teamModels,
            playersTotal,
            playerModels
        ) = try await (
            leaguesCountFuture,
            leagueModelsFuture,
            teamsCountFuture,
            teamModelsFuture,
            playersCountFuture,
            playerModelsFuture
        )

        // --------------------------------------------------------------
        // MAPPING
        // --------------------------------------------------------------

        // LEAGUE → AppLeagueOverview
        let leagueOverviews: [AppModels.AppLeagueOverview] = try leagueModels.map {
            try $0.toAppLeagueOverview()
        }

        // TEAM → AppTeamOverview
        let teamOverviews: [AppModels.AppTeamOverview] = try teamModels.map { t in
            let leagueOverview = try t.league?.toAppLeagueOverview()
            ?? AppModels.AppLeagueOverview(
                id: UUID(),
                name: "Unknown",
                code: "",
                state: .wien
            )

            return AppModels.AppTeamOverview(
                id: try t.requireID(),
                sid: t.sid ?? "",
                league: leagueOverview,
                points: t.points,
                logo: t.logo,
                name: t.teamName,
                stats: nil // fast search → skip heavy stats here
            )
        }

        // PLAYER → AppPlayerOverview
        let playerOverviews: [AppModels.AppPlayerOverview] = try playerModels.compactMap { p in
            guard let team = p.team else { return nil }

            let leagueOverview = try team.league?.toAppLeagueOverview()
            ?? AppModels.AppLeagueOverview(
                id: UUID(),
                name: "Unknown",
                code: "",
                state: .wien
            )

            let teamOverview = AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: leagueOverview,
                points: team.points,
                logo: team.logo,
                name: team.teamName,
                stats: nil
            )

            return AppModels.AppPlayerOverview(
                id: try p.requireID(),
                sid: p.sid,
                name: p.name,
                number: p.number,
                nationality: p.nationality,
                eligilibity: p.eligibility,
                image: p.image ?? "",
                status: p.status ?? false,
                team: teamOverview,
                nextMatch: [] // keep lightweight for search results
            )
        }

        // --------------------------------------------------------------
        // RESPONSE
        // --------------------------------------------------------------
        return AppSearchResults(
            players: playerOverviews,
            playersCount: playersTotal,
            teams: teamOverviews,
            teamsCount: teamsTotal,
            leagues: leagueOverviews,
            leaguesCount: leaguesTotal
        )
    }
}
