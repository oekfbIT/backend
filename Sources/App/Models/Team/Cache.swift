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
        return TeamStatsCache.query(on: db)
            .filter(\.$team.$id == teamID)
            .first()
            .flatMap { cache in
                // Check cache age (15 minutes)
                if let cache = cache, let updated = cache.updatedAt, updated > Date().addingTimeInterval(-900),
                   !onlyPrimarySeason { // ⚠️ don’t reuse cache if primary season requested
                    return db.eventLoop.makeSucceededFuture(teamStats(from: cache))
                }

                // Compute and update cache
                let fallback = cache.map { teamStats(from: $0) } ?? emptyTeamStats()
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
                    .flatMapError { _ in
                        // Prefer an older cached value to failing a response;
                        // otherwise return neutral statistics.
                        db.eventLoop.makeSucceededFuture(fallback)
                    }
            }
            .flatMapError { _ in db.eventLoop.makeSucceededFuture(emptyTeamStats()) }
    }


    static func getPlayerStats(for playerID: UUID, on db: Database) -> EventLoopFuture<PlayerStats> {
        getPlayerStats(for: [playerID], on: db)
            .map { $0[playerID] ?? PlayerStatisticsService.emptyStats() }
    }

    /// Fetches a roster's cached statistics in one query. Cache misses are
    /// calculated together, so opening a team never triggers one calculation
    /// per player.
    static func getPlayerStats(
        for playerIDs: [UUID],
        on db: Database
    ) -> EventLoopFuture<[UUID: PlayerStats]> {
        let uniqueIDs = Array(Set(playerIDs))
        guard !uniqueIDs.isEmpty else {
            return db.eventLoop.makeSucceededFuture([:])
        }

        let emptyResult = Dictionary(uniqueKeysWithValues: uniqueIDs.map {
            ($0, PlayerStatisticsService.emptyStats())
        })

        return PlayerStatsCache.query(on: db)
            .filter(\.$player.$id ~~ uniqueIDs)
            .all()
            .flatMap { caches in
                let now = Date()
                var result = [UUID: PlayerStats]()
                for cache in caches {
                    guard
                        let updated = cache.updatedAt,
                        updated > now.addingTimeInterval(-900)
                    else { continue }
                    result[cache.$player.id] = playerStats(from: cache)
                }

                let missingIDs = uniqueIDs.filter { result[$0] == nil }
                guard !missingIDs.isEmpty else {
                    return db.eventLoop.makeSucceededFuture(result)
                }

                return PlayerStatisticsService.calculate(playerIDs: missingIDs, on: db)
                    .flatMap { calculated in
                        for playerID in missingIDs {
                            result[playerID] = calculated[playerID]?.all ?? PlayerStatisticsService.emptyStats()
                        }

                        // Old deployments did not enforce a unique cache row.
                        // Keep the first row rather than crashing on a legacy
                        // duplicate while the request is being served.
                        var cachesByPlayer = [UUID: PlayerStatsCache]()
                        for cache in caches {
                            let playerID = cache.$player.id
                            if cachesByPlayer[playerID] == nil {
                                cachesByPlayer[playerID] = cache
                            }
                        }
                        let saves = missingIDs.map { playerID -> EventLoopFuture<Void> in
                            let cache = cachesByPlayer[playerID] ?? PlayerStatsCache()
                            let stats = result[playerID] ?? PlayerStatisticsService.emptyStats()
                            cache.$player.id = playerID
                            cache.matchesPlayed = stats.matchesPlayed
                            cache.goalsScored = stats.goalsScored
                            cache.yellowCards = stats.yellowCards
                            cache.redCards = stats.redCards
                            cache.yellowRedCards = stats.yellowRedCrd
                            cache.goalsAverage = stats.goalsAverage
                            return cache.save(on: db)
                        }

                        // A cache write is an optimization. Never fail a live
                        // game request because one cache document could not save.
                        return EventLoopFuture.andAllComplete(saves, on: db.eventLoop)
                            .transform(to: result)
                    }
            }
            .flatMapError { _ in
                // A cache/database failure must not take the API down. Return
                // neutral stats and allow a later request to refresh the cache.
                db.eventLoop.makeSucceededFuture(emptyResult)
            }
    }

    private static func playerStats(from cache: PlayerStatsCache) -> PlayerStats {
        PlayerStats(
            matchesPlayed: cache.matchesPlayed,
            goalsScored: cache.goalsScored,
            redCards: cache.redCards,
            yellowCards: cache.yellowCards,
            yellowRedCrd: cache.yellowRedCards,
            goalsAverage: cache.goalsAverage
        )
    }

    private static func teamStats(from cache: TeamStatsCache) -> TeamStats {
        TeamStats(
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
    }

    private static func emptyTeamStats() -> TeamStats {
        TeamStats(
            wins: 0,
            draws: 0,
            losses: 0,
            totalScored: 0,
            totalAgainst: 0,
            goalDifference: 0,
            totalPoints: 0,
            totalYellowCards: 0,
            totalRedCards: 0
        )
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
