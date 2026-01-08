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

        // Resolve primary season if needed
        let primarySeasonID: UUID? = {
            guard scope == .primary else { return nil }
            return try? Season.query(on: req.db)
                .filter(\.$league.$id == leagueID)
                .filter(\.$primary == true)
                .first()
                .unwrap(or: Abort(.notFound, reason: "No primary season"))
                .wait()
                .id
        }()

        // Teams + players
        let teams = try await Team.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$players)
            .all()

        // Build player → team lookup
        var playerTeam: [UUID: (String?, String?, String?)] = [:]
        for team in teams {
            let teamID = team.id?.uuidString
            for player in team.players {
                if let pid = player.id {
                    playerTeam[pid] = (team.logo, team.teamName, teamID)
                }
            }
        }

        let playerIDs = Array(playerTeam.keys)
        if playerIDs.isEmpty { return [] }

        // Events
        var query = MatchEvent.query(on: req.db)
            .filter(\.$player.$id ~~ playerIDs)
            .filter(\.$type == type)

        if let seasonID = primarySeasonID {
            query = query
                .join(parent: \MatchEvent.$match)
                .filter(Match.self, \.$season.$id == seasonID)
        }

        let events = try await query.all()
        return mapToLeaderboard(events, playerTeam: playerTeam)
    }

    // MARK: Mapper

    private func mapToLeaderboard(
        _ events: [MatchEvent],
        playerTeam: [UUID: (String?, String?, String?)]
    ) -> [LeaderBoard] {

        var counts: [UUID: (String?, String?, String?, Int)] = [:]

        for event in events {
            guard let pid = event.$player.id else { continue }

            if let existing = counts[pid] {
                counts[pid] = (existing.0, existing.1, existing.2, existing.3 + 1)
            } else {
                counts[pid] = (event.name, event.image, event.number, 1)
            }
        }

        return counts
            .map { pid, data in
                let (teamImg, teamName, teamId) = playerTeam[pid] ?? (nil, nil, nil)
                return LeaderBoard(
                    name: data.0,
                    image: data.1,
                    number: data.2,
                    count: Double(data.3),
                    playerid: pid,
                    teamimg: teamImg,
                    teamName: teamName,
                    teamId: teamId
                )
            }
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
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

        // 2) Get goal counts per player for matches in those primary seasons.
        // We do this in SQL-ish style: fetch the relevant goal events, then count per player.
        // (Fluent doesn't have a perfect portable GROUP BY API, so we keep it simple and fast:
        // filter early by seasons and type, then aggregate in memory *on a much smaller dataset*.)
        let goalEvents = try await MatchEvent.query(on: req.db)
            .filter(\.$type == .goal)
            .join(parent: \MatchEvent.$match)
            .filter(Match.self, \.$season.$id ~~ primarySeasonIDs)
            .all()

        // Count goals per player id
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(1024)

        for e in goalEvents {
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
