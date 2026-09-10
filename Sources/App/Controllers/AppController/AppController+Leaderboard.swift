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
        let entries = try await LeaderboardService.fetch(leagueID: nil, eventType: .goal, primaryOnly: true, on: req.db).get()
        return entries.prefix(100).compactMap { entry in
            guard let id = entry.playerid else { return nil }
            return TopGoalscorerDTO(player_id: id, player_image: entry.image, name: entry.name,
                goals: Int(entry.count ?? 0), team_name: entry.teamName, team_logo: entry.teamimg)
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
