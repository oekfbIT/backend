//
//  AppController+Leaderboard.swift
//  oekfbbackend
//

import Vapor
import Fluent

// MARK: - Leaderboard (AppController)
extension AppController {

    // MARK: Routes
    func setupLeaderboardRoutes(on root: RoutesBuilder) {
        let lb = root.grouped("leaderboard")

        // All-time
        lb.get("league", ":id", "goals", use: goalLeaderboardAllTime)
        lb.get("league", ":id", "yellowCards", use: yellowCardLeaderboardAllTime)
        lb.get("league", ":id", "redCards", use: redCardLeaderboardAllTime)
        lb.get("league", ":id", "yellowRedCards", use: yellowRedCardLeaderboardAllTime)

        // Primary season
        lb.get("league", ":id", "primary", "goals", use: goalLeaderboardPrimary)
        lb.get("league", ":id", "primary", "yellowCards", use: yellowCardLeaderboardPrimary)
        lb.get("league", ":id", "primary", "redCards", use: redCardLeaderboardPrimary)
        lb.get("league", ":id", "primary", "yellowRedCards", use: yellowRedCardLeaderboardPrimary)
        lb.get("primary", "goals", "top", use: getTopGoalscorersPrimaryAcrossAllLeagues)

    }

    // MARK: Public handlers (ALL-TIME)

    func goalLeaderboardAllTime(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .goal, scope: .alltime)
    }

    func yellowCardLeaderboardAllTime(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .yellowCard, scope: .alltime)
    }

    func redCardLeaderboardAllTime(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .redCard, scope: .alltime)
    }

    func yellowRedCardLeaderboardAllTime(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .yellowRedCard, scope: .alltime)
    }

    // MARK: Public handlers (PRIMARY SEASON)

    func goalLeaderboardPrimary(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .goal, scope: .primary)
    }

    func yellowCardLeaderboardPrimary(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .yellowCard, scope: .primary)
    }

    func redCardLeaderboardPrimary(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .redCard, scope: .primary)
    }

    func yellowRedCardLeaderboardPrimary(req: Request) async throws -> [LeaderBoard] {
        try await leaderboard(req: req, type: .yellowRedCard, scope: .primary)
    }

    // MARK: Core logic

    private enum LeaderboardScope {
        case alltime
        case primary
    }

    private func leaderboard(
        req: Request,
        type: MatchEventType,
        scope: LeaderboardScope
    ) async throws -> [LeaderBoard] {

        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID")
        }
        return try await LeaderboardService.fetch(
            leagueID: leagueID,
            eventType: type,
            primaryOnly: scope == .primary,
            on: req.db
        ).get()
    }
    
    
    /// GET /app/leaderboard/primary/goals/top
    /// Top 100 goalscorers across ALL leagues, PRIMARY seasons only.
    /// Returns: player_id, name, goals, team_name, team_logo
    func getTopGoalscorersPrimaryAcrossAllLeagues(req: Request) async throws -> [TopGoalscorerDTO] {

        // 1) primary season ids (small set)
        let primarySeasonIDs = try await Season.query(on: req.db)
            .filter(\.$primary == true)
            .all(\.$id)

        guard !primarySeasonIDs.isEmpty else { return [] }

        let primaryMatches = try await Match.query(on: req.db)
            .filter(\.$season.$id ~~ primarySeasonIDs)
            .all()
            .filter(PlayerStatisticsService.countsAsAppearance)
        let primaryMatchIDs = primaryMatches.compactMap(\.id)
        guard !primaryMatchIDs.isEmpty else { return [] }

        // 2) Get personal goal counts for played matches in those primary seasons.
        let goalEvents = try await MatchEvent.query(on: req.db)
            .filter(\.$type == .goal)
            .filter(\.$match.$id ~~ primaryMatchIDs)
            .all()

        // Count goals per player id
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(1024)

        for e in goalEvents where e.ownGoal != true {
            guard let pid = e.$player.id else { continue }
            counts[pid, default: 0] += 1
        }

        // top 100 player ids
        let topPlayerIDs: [UUID] = counts
            .sorted { $0.value > $1.value }
            .prefix(100)
            .map { $0.key }

        guard !topPlayerIDs.isEmpty else { return [] }

        // 3) Fetch players (ONLY the top 100) + team info
        // NOTE: adjust field names if your Player model differs.
        let players = try await Player.query(on: req.db)
            .filter(\.$id ~~ topPlayerIDs)
            .with(\.$team)
            .all()

        // index players by id
        var playerById: [UUID: Player] = [:]
        playerById.reserveCapacity(players.count)
        for p in players {
            if let id = p.id { playerById[id] = p }
        }

        // 4) Build DTOs in the same order as topPlayerIDs (already sorted by goals)
        return topPlayerIDs.compactMap { pid in
            let goals = counts[pid] ?? 0
            let p = playerById[pid]

            return TopGoalscorerDTO(
                player_id: pid,
                player_image: p?.image,
                name: p?.name,
                goals: goals,
                team_name: p?.team?.teamName,
                team_logo: p?.team?.logo
            )
        }
    }

}

// MARK: - Compact DTO for app
struct TopGoalscorerDTO: Content {
    let player_id: UUID
    let player_image: String?
    let name: String?
    let goals: Int
    let team_name: String?
    let team_logo: String?
}
