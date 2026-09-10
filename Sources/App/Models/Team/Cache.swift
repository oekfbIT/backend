//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 17.10.25.
//

import Vapor
import Fluent

final class TeamStatsCache: Model, Content {
    static let schema = "team_stats_cache"

    @ID(key: .id) var id: UUID?
    @Parent(key: "team_id") var team: Team

    @Field(key: "wins") var wins: Int
    @Field(key: "draws") var draws: Int
    @Field(key: "losses") var losses: Int
    @Field(key: "total_scored") var totalScored: Int
    @Field(key: "total_against") var totalAgainst: Int
    @Field(key: "goal_difference") var goalDifference: Int
    @Field(key: "points") var totalPoints: Int
    @Field(key: "yellow_cards") var totalYellowCards: Int
    @Field(key: "red_cards") var totalRedCards: Int
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
}

final class PlayerStatsCache: Model, Content {
    static let schema = "player_stats_cache"

    @ID(key: .id) var id: UUID?
    @Parent(key: "player_id") var player: Player

    @Field(key: "matches_played") var matchesPlayed: Int
    @Field(key: "goals_scored") var goalsScored: Int
    @Field(key: "yellow_cards") var yellowCards: Int
    @Field(key: "red_cards") var redCards: Int
    @Field(key: "yellow_red_cards") var yellowRedCards: Int
    @Field(key: "goal_avg") var goalsAverage: Double?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
}


extension Team {
    static func computeTeamStats(
        for teamID: UUID,
        on db: Database,
        onlyPrimarySeason: Bool = false
    ) -> EventLoopFuture<TeamStats> {
        getTeamStats(teamID: teamID, db: db, onlyPrimarySeason: onlyPrimarySeason)
    }
}


extension Player {
    static func computePlayerStats(for playerID: UUID, on db: Database) -> EventLoopFuture<PlayerStats> {
        PlayerStatisticsService.calculate(playerID: playerID, on: db).map(\.all)
    }
}

enum StatsCacheManager {
    static func invalidatePlayerStats(for playerIDs: [UUID], on db: Database) -> EventLoopFuture<Void> {
        let uniqueIDs = Array(Set(playerIDs))
        guard !uniqueIDs.isEmpty else {
            return db.eventLoop.makeSucceededFuture(())
        }
        Caches.seasons.clear()
        return PlayerStatsCache.query(on: db)
            .filter(\.$player.$id ~~ uniqueIDs)
            .delete()
    }

    static func invalidateStats(for match: Match, on db: Database) -> EventLoopFuture<Void> {
        Caches.seasons.clear()

        let deleteTeamCache = TeamStatsCache.query(on: db)
            .group(.or) { group in
                group.filter(\.$team.$id == match.$homeTeam.id)
                group.filter(\.$team.$id == match.$awayTeam.id)
            }
            .delete()

        guard let matchID = match.id else {
            return deleteTeamCache
        }

        let blanketPlayerIDs = (match.homeBlanket?.players.map(\.id) ?? [])
            + (match.awayBlanket?.players.map(\.id) ?? [])
        let deletePlayerCache = MatchEvent.query(on: db)
            .filter(\.$match.$id == matchID)
            .all()
            .flatMap { events in
                let eventPlayerIDs = events.compactMap { $0.$player.id }
                return invalidatePlayerStats(
                    for: blanketPlayerIDs + eventPlayerIDs,
                    on: db
                )
            }

        return deleteTeamCache.and(deletePlayerCache).transform(to: ())
    }

    static func getTeamStats(for teamID: UUID, on db: Database, onlyPrimarySeason: Bool = false) -> EventLoopFuture<TeamStats> {
        // Old persisted rows cannot be trusted after event deletion or season changes.
        TeamStatisticsService.calculate(teamIDs: [teamID], primaryOnly: onlyPrimarySeason, on: db).map {
            let pair = $0[teamID]
            return (onlyPrimarySeason ? pair?.season : pair?.all) ?? TeamStatisticsService.emptyStats()
        }
    }


    static func getPlayerStats(for playerID: UUID, on db: Database) -> EventLoopFuture<PlayerStats> {
        getPlayerStats(for: [playerID], on: db)
            .map { $0[playerID] ?? PlayerStatisticsService.emptyStats() }
    }

    /// One indexed batch, without persisting stale totals or false zeroes.
    static func getPlayerStats(for playerIDs: [UUID], on db: Database) -> EventLoopFuture<[UUID: PlayerStats]> {
        PlayerStatisticsService.calculate(playerIDs: playerIDs, on: db).map { $0.mapValues(\.all) }
    }
}

extension Team {
    static func getTeamStats(teamID: UUID, db: Database, onlyPrimarySeason: Bool = false) -> EventLoopFuture<TeamStats> {
        StatsCacheManager.getTeamStats(for: teamID, on: db, onlyPrimarySeason: onlyPrimarySeason)
    }
}

// MARK: - Stats Cache Invalidation Helper
extension MatchController {
    func invalidateStats(for match: Match, on db: Database) -> EventLoopFuture<Void> {
        StatsCacheManager.invalidateStats(for: match, on: db)
    }
}
