//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 18.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - LEAGUE ENDPOINTS
extension AppController {
    func setupLeagueRoutes(on root: RoutesBuilder) {
        let league = root.grouped("league")

        league.get(":leagueID", use: getLeagueByID)
        league.get("code", ":code", use: getLeagueByCode)

        league.get(":leagueID", "teams", use: getTeamsByLeagueID)
        league.get("code", ":code", "teams", use: getTeamsByLeagueCode)

        league.get(":leagueID", "fixtures", use: getFixturesByLeagueID)
        league.get("code", ":code", "fixtures", use: getFixturesByLeagueCode)

//        league.get(":leagueID", "table", use: getLeagueTableByID)
        league.get(":leagueID", "table", use: getLeagueCurrentSeasonTable_CLONE)
        league.get("primary", use: getAllPrimaryLeagueOverviews)
    }

    
    // GET /app/league/primary
    func getAllPrimaryLeagueOverviews(req: Request) async throws -> [AppModels.AppLeagueOverview] {
        // 1️⃣ Fetch all primary seasons and preload their leagues
        let primarySeasons = try await Season.query(on: req.db)
            .filter(\.$primary == true)
            .with(\.$league)
            .all()

        // 2️⃣ Deduplicate each league while retaining its primary-season summary.
        let primaryLeaguePairs = Dictionary(
            grouping: primarySeasons.compactMap { season -> (league: League, season: Season)? in
                guard let league = season.league, league.visibility == true else { return nil }
                return (league, season)
            }
        ) { pair in
            pair.league.id
        }.compactMap { $0.value.first }

        // 3️⃣ Return all metadata required by the list in one response.
        let overviews = try primaryLeaguePairs.map { pair in
            AppModels.AppLeagueOverview(
                id: try pair.league.requireID(),
                name: pair.league.name,
                code: pair.league.code ?? "",
                state: pair.league.state ?? .wien,
                logo: pair.league.logo,
                teamCount: pair.league.teamcount,
                seasonName: pair.season.name
            )
        }

        // 4️⃣ Sort alphabetically by state, then name
        return overviews.sorted {
            if $0.state == $1.state {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.state.rawValue < $1.state.rawValue
        }
    }
 
    func getLeagueByID(req: Request) async throws -> AppModels.AppLeague {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let overview = try league.toAppLeagueOverview()

        // Batch current-season team statistics for this league.
        let teamStats = try await TeamStatisticsService.calculate(teamIDs: league.teams.compactMap(\.id), primaryOnly: true, on: req.db).get()
        let teams = try await league.teams.asyncMap { team in
            let stats = teamStats[try team.requireID()]?.season ?? TeamStatisticsService.emptyStats()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: overview,
                points: stats.totalPoints,
                logo: team.logo,
                name: team.teamName,
                shortName: team.shortName,
                stats: stats
            )
        }

        // Build league table directly from teams
        var tableItems = try await buildLeagueTable(for: league, on: req, onlyPrimarySeason: true)

        // Sort by points, then goal difference
        tableItems.sort {
            if $0.points == $1.points {
                return $0.difference > $1.difference
            }
            return $0.points > $1.points
        }

        // Assign ranking positions
        for i in 0..<tableItems.count {
            tableItems[i].ranking = i + 1
        }

        return try league.toAppLeague(teams: teams, table: tableItems)
    }

    func getLeagueByCode(req: Request) async throws -> AppModels.AppLeague {
        guard let code = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league code.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$code == code)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let overview = try league.toAppLeagueOverview()

        // Batch current-season team statistics for this league.
        let teamStats = try await TeamStatisticsService.calculate(teamIDs: league.teams.compactMap(\.id), primaryOnly: true, on: req.db).get()
        let teams = try await league.teams.asyncMap { team in
            let stats = teamStats[try team.requireID()]?.season ?? TeamStatisticsService.emptyStats()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: overview,
                points: stats.totalPoints,
                logo: team.logo,
                name: team.teamName,
                shortName: team.shortName,
                stats: stats
            )
        }

        // Build league table directly from teams
        var tableItems = try await buildLeagueTable(for: league, on: req, onlyPrimarySeason: true)

        // Sort by points, then goal difference
        tableItems.sort {
            if $0.points == $1.points {
                return $0.difference > $1.difference
            }
            return $0.points > $1.points
        }

        // Assign ranking positions
        for i in 0..<tableItems.count {
            tableItems[i].ranking = i + 1
        }

        return try league.toAppLeague(teams: teams, table: tableItems)
    }
    
    // GET /app/league/:leagueID/teams
    func getTeamsByLeagueID(req: Request) async throws -> [AppModels.AppTeamOverview] {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let leagueOverview = try league.toAppLeagueOverview()

        let teamStats = try await TeamStatisticsService.calculate(teamIDs: league.teams.compactMap(\.id), primaryOnly: true, on: req.db).get()
        return try await league.teams.asyncMap { team in
            let stats = teamStats[try team.requireID()]?.season ?? TeamStatisticsService.emptyStats()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: leagueOverview,
                points: stats.totalPoints,
                logo: team.logo,
                name: team.teamName,
                shortName: team.shortName,
                stats: stats
            )
        }
    }

    // GET /app/league/code/:code/teams
    func getTeamsByLeagueCode(req: Request) async throws -> [AppModels.AppTeamOverview] {
        guard let code = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league code.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$code == code)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let leagueOverview = try league.toAppLeagueOverview()

        let teamStats = try await TeamStatisticsService.calculate(teamIDs: league.teams.compactMap(\.id), primaryOnly: true, on: req.db).get()
        return try await league.teams.asyncMap { team in
            let stats = teamStats[try team.requireID()]?.season ?? TeamStatisticsService.emptyStats()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: leagueOverview,
                points: stats.totalPoints,
                logo: team.logo,
                name: team.teamName,
                shortName: team.shortName,
                stats: stats
            )
        }
    }
    
    // GET /app/league/:leagueID/fixtures
    func getFixturesByLeagueID(req: Request) async throws -> [GameDayGroup] {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        // 1️⃣ Load league
        guard let league = try await League.find(leagueID, on: req.db) else {
            throw Abort(.notFound, reason: "League not found.")
        }

        // 2️⃣ Get all primary seasons for this league
        let seasons = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$primary == true)
            .all()

        let seasonIDs = try seasons.map { try $0.requireID() }

        // 3️⃣ Get all matches from those seasons
        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id ~~ seasonIDs)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        // 4️⃣ Group by gameday and sort
        let grouped = Dictionary(grouping: matches) { $0.details.gameday }
            .sorted { $0.key < $1.key }

        let leagueOverview = try league.toAppLeagueOverview()

        // 5️⃣ Convert into compact [GameDayGroup]
        let groups: [GameDayGroup] = try await grouped.asyncMap { (day, matchesForDay) in
            let sortedMatches = matchesForDay.sorted {
                ($0.details.date ?? .distantPast) < ($1.details.date ?? .distantPast)
            }

            let appMatches = try await sortedMatches.asyncMap { match in
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
                    status: match.status,
                    firstHalfStartDate: match.firstHalfEndDate,
                    secondHalfStartDate: match.secondHalfStartDate

                )
            }

            return GameDayGroup(
                gameday: day,
                date: matchesForDay.compactMap(\.details.date).min(),
                matches: appMatches
            )
        }

        return groups
    }

    // GET /app/league/code/:code/fixtures
    func getFixturesByLeagueCode(req: Request) async throws -> [GameDayGroup] {
        guard let code = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league code.")
        }

        // 1️⃣ Find league by code
        guard let league = try await League.query(on: req.db)
            .filter(\.$code == code)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let leagueID = try league.requireID()

        // 2️⃣ Get all primary seasons
        let seasons = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$primary == true)
            .all()

        let seasonIDs = try seasons.map { try $0.requireID() }

        // 3️⃣ Get matches
        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id ~~ seasonIDs)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        // 4️⃣ Group and sort
        let grouped = Dictionary(grouping: matches) { $0.details.gameday }
            .sorted { $0.key < $1.key }

        let leagueOverview = try league.toAppLeagueOverview()

        // 5️⃣ Convert to compact AppMatchOverview
        let groups: [GameDayGroup] = try await grouped.asyncMap { (day, matchesForDay) in
            let sortedMatches = matchesForDay.sorted {
                ($0.details.date ?? .distantPast) < ($1.details.date ?? .distantPast)
            }

            let appMatches = try await sortedMatches.asyncMap { match in
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
                    name: away.teamName, shortName: away.shortName,
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
                    status: match.status,
                    firstHalfStartDate: match.firstHalfEndDate,
                    secondHalfStartDate: match.secondHalfStartDate

                )
            }

            return GameDayGroup(
                gameday: day,
                date: matchesForDay.compactMap(\.details.date).min(),
                matches: appMatches
            )
        }

        return groups
    }
    
    // MARK: - Get League Table by League ID (Primary Season Only)
    func getLeagueTableByID(req: Request) async throws -> [TableItem] {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        // ✅ Desktop equivalent: NOT primary-season restricted
        var tableItems = try await buildLeagueTable(for: league, on: req, onlyPrimarySeason: true)

        tableItems.sort {
            if $0.points == $1.points {
                return $0.difference > $1.difference
            }
            return $0.points > $1.points
        }

        for i in 0..<tableItems.count {
            tableItems[i].ranking = i + 1
        }

        return tableItems
    }

    // MARK: - CURRENT SEASON TABLE (EXACT webClient clone)
    // MARK: - CURRENT SEASON TABLE (CLONE + FORM)
    func getLeagueCurrentSeasonTable_CLONE(req: Request) async throws -> [TableItem] {
        let leagueID = try req.parameters.require("leagueID", as: UUID.self)
        return try await TeamStatisticsService.table(leagueID: leagueID, primaryOnly: true, on: req.db).get()
    }

}
