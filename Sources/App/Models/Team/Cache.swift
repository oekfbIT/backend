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

    static func getTeamStats(
        for teamID: UUID,
        on db: Database,
        onlyPrimarySeason: Bool = false
    ) -> EventLoopFuture<TeamStats> {
        TeamStatsCache.query(on: db)
            .filter(\.$team.$id == teamID)
            .first()
            .flatMap { cache in
                // Check cache age (15 minutes)
                if let cache = cache, let updated = cache.updatedAt, updated > Date().addingTimeInterval(-900),
                   !onlyPrimarySeason { // ⚠️ don’t reuse cache if primary season requested
                    let stats = TeamStats(
                        wins: cache.wins,
                        draws: cache.draws,
                        losses: cache.losses,
                        totalScored: cache.totalScored,
                        totalAgainst: cache.totalAgainst,
                        goalDifference: cache.goalDifference,
                        totalPoints: cache.totalPoints,
                        totalYellowCards: cache.totalYellowCards,
                        totalRedCards: cache.totalRedCards
                    )
                    return db.eventLoop.makeSucceededFuture(stats)
                }

                // Compute and update cache
                return Team.computeTeamStats(for: teamID, on: db, onlyPrimarySeason: onlyPrimarySeason)
                    .flatMap { stats in
                        // If we’re computing global stats, save to cache
                        if !onlyPrimarySeason {
                            let cache = cache ?? TeamStatsCache()
                            cache.$team.id = teamID
                            cache.wins = stats.wins
                            cache.draws = stats.draws
                            cache.losses = stats.losses
                            cache.totalScored = stats.totalScored
                            cache.totalAgainst = stats.totalAgainst
                            cache.goalDifference = stats.goalDifference
                            cache.totalPoints = stats.totalPoints
                            cache.totalYellowCards = stats.totalYellowCards
                            cache.totalRedCards = stats.totalRedCards
                            return cache.save(on: db).transform(to: stats)
                        } else {
                            // Don’t cache primary-season-only queries
                            return db.eventLoop.makeSucceededFuture(stats)
                        }
                    }
            }
    }


    static func getPlayerStats(for playerID: UUID, on db: Database) -> EventLoopFuture<PlayerStats> {
        PlayerStatsCache.query(on: db)
            .filter(\.$player.$id == playerID)
            .first()
            .flatMap { cache in
                if let cache = cache, let updated = cache.updatedAt, updated > Date().addingTimeInterval(-900) {
                    let stats = PlayerStats(
                        matchesPlayed: cache.matchesPlayed,
                        goalsScored: cache.goalsScored,
                        redCards: cache.redCards,
                        yellowCards: cache.yellowCards,
                        yellowRedCrd: cache.yellowRedCards,
                        goalsAverage: cache.goalsAverage
                    )
                    return db.eventLoop.makeSucceededFuture(stats)
                }

                return Player.computePlayerStats(for: playerID, on: db)
                    .flatMap { stats in
                        let cache = cache ?? PlayerStatsCache()
                        cache.$player.id = playerID
                        cache.matchesPlayed = stats.matchesPlayed
                        cache.goalsScored = stats.goalsScored
                        cache.redCards = stats.redCards
                        cache.yellowCards = stats.yellowCards
                        cache.yellowRedCards = stats.yellowRedCrd
                        cache.goalsAverage = stats.goalsAverage
                        return cache.save(on: db).transform(to: stats)
                    }
            }
    }
}

extension Team {
    static func getTeamStats(
        teamID: UUID,
        db: Database,
        onlyPrimarySeason: Bool = false
    ) -> EventLoopFuture<TeamStats> {
        var query = Match.query(on: db)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                or.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status == .done)
            .with(\.$events)   // 🔹 no nested .with(\.$player)

        // 🔹 Only include matches from the current primary season if requested
        if onlyPrimarySeason {
            query = query
                .join(parent: \Match.$season)
                .filter(Season.self, \.$primary == true)
        }

        return query.all().map { matches in
            var wins = 0
            var draws = 0
            var losses = 0
            var totalScored = 0
            var totalAgainst = 0
            var totalYellow = 0
            var totalRed = 0

            for match in matches {
                let homeID = match.$homeTeam.id
                let awayID = match.$awayTeam.id
                let homeScore = match.score.home
                let awayScore = match.score.away

                // 🔹 goals / result
                if teamID == homeID {
                    totalScored += homeScore
                    totalAgainst += awayScore
                    if homeScore > awayScore { wins += 1 }
                    else if homeScore == awayScore { draws += 1 }
                    else { losses += 1 }
                } else if teamID == awayID {
                    totalScored += awayScore
                    totalAgainst += homeScore
                    if awayScore > homeScore { wins += 1 }
                    else if homeScore == awayScore { draws += 1 }
                    else { losses += 1 }
                }

                // 🔹 cards: derive team via assign + match.home/away
                let isHomeTeam = (homeID == teamID)
                let isAwayTeam = (awayID == teamID)

                for event in match.events {
                    guard let assign = event.assign else {
                        // no assignment, can't reliably attribute → skip
                        continue
                    }

                    let belongsToTeam: Bool
                    switch assign {
                    case .home:
                        belongsToTeam = isHomeTeam
                    case .away:
                        belongsToTeam = isAwayTeam
                    }

                    guard belongsToTeam else { continue }

                    switch event.type {
                    case .yellowCard:
                        totalYellow += 1
                    case .redCard, .yellowRedCard:
                        totalRed += 1
                    default:
                        break
                    }
                }
            }

            return TeamStats(
                wins: wins,
                draws: draws,
                losses: losses,
                totalScored: totalScored,
                totalAgainst: totalAgainst,
                goalDifference: totalScored - totalAgainst,
                totalPoints: wins * 3 + draws,
                totalYellowCards: totalYellow,
                totalRedCards: totalRed
            )
        }
    }
}



// MARK: - Stats Cache Invalidation Helper
extension MatchController {
    func invalidateStats(for match: Match, on db: Database) -> EventLoopFuture<Void> {
        StatsCacheManager.invalidateStats(for: match, on: db)
    }
}
