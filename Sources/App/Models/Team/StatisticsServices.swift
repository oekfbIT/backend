import Fluent
import Vapor

/// One source of truth for player statistics used by the website and app APIs.
enum PlayerStatisticsService {
    static func contains(_ playerID: UUID, in match: Match) -> Bool {
        let homeContains = match.homeBlanket?.players.contains { $0.id == playerID } ?? false
        let awayContains = match.awayBlanket?.players.contains { $0.id == playerID } ?? false
        return homeContains || awayContains
    }

    static func countsAsAppearance(_ match: Match) -> Bool {
        switch match.status {
        case .pending, .cancelled:
            return false
        default:
            return true
        }
    }

    static func calculate(
        playerID: UUID,
        activeLeagueID: UUID? = nil,
        on db: Database
    ) -> EventLoopFuture<PlayerStatsPair> {
        let matches = Match.query(on: db)
            .with(\.$season)
            .all()
        let events = MatchEvent.query(on: db)
            .filter(\.$player.$id == playerID)
            .all()

        return matches.and(events).map { matches, events in
            let eventMatchIDs = Set(events.map { $0.$match.id })
            let relevantMatches = matches.filter {
                contains(playerID, in: $0) || $0.id.map(eventMatchIDs.contains) == true
            }
            let countableMatches = relevantMatches.filter(countsAsAppearance)
            let countableMatchIDs = Set(countableMatches.compactMap(\.id))
            let activeMatchIDs = Set(countableMatches.compactMap { match -> UUID? in
                guard match.season?.primary == true else { return nil }
                if let activeLeagueID, match.season?.$league.id != activeLeagueID {
                    return nil
                }
                return match.id
            })

            var all = emptyStats()
            var season = emptyStats()
            all.matchesPlayed = countableMatchIDs.count
            season.matchesPlayed = activeMatchIDs.count

            for event in events where countableMatchIDs.contains(event.$match.id) {
                add(event, to: &all)
                if activeMatchIDs.contains(event.$match.id) {
                    add(event, to: &season)
                }
            }

            all.goalsAverage = average(goals: all.goalsScored, appearances: all.matchesPlayed)
            season.goalsAverage = average(goals: season.goalsScored, appearances: season.matchesPlayed)
            return PlayerStatsPair(all: all, season: season)
        }
    }

    static func emptyStats() -> PlayerStats {
        PlayerStats(
            matchesPlayed: 0,
            goalsScored: 0,
            redCards: 0,
            yellowCards: 0,
            yellowRedCrd: 0,
            goalsAverage: nil
        )
    }

    private static func add(_ event: MatchEvent, to stats: inout PlayerStats) {
        switch event.type {
        case .goal where event.ownGoal != true:
            stats.goalsScored += 1
        case .redCard:
            stats.redCards += 1
        case .yellowCard:
            stats.yellowCards += 1
        case .yellowRedCard:
            stats.yellowRedCrd += 1
        default:
            break
        }
    }

    private static func average(goals: Int, appearances: Int) -> Double? {
        appearances > 0 ? Double(goals) / Double(appearances) : nil
    }
}

/// League leaderboards are scoped by the seasons/matches belonging to a league,
/// not by a player's current team. This keeps transferred players and historic
/// events in the correct league.
enum LeaderboardService {
    static func fetch(
        leagueID: UUID,
        eventType: MatchEventType,
        primaryOnly: Bool,
        on db: Database
    ) -> EventLoopFuture<[LeaderBoard]> {
        var seasonQuery = Season.query(on: db)
            .filter(\.$league.$id == leagueID)
        if primaryOnly {
            seasonQuery = seasonQuery.filter(\.$primary == true)
        }

        return seasonQuery.all(\.$id).flatMap { seasonIDs in
            guard !seasonIDs.isEmpty else {
                return db.eventLoop.makeSucceededFuture([])
            }

            return Match.query(on: db)
                .filter(\.$season.$id ~~ seasonIDs)
                .with(\.$homeTeam)
                .with(\.$awayTeam)
                .all()
                .flatMap { matches in
                    let countableMatches = matches.filter(PlayerStatisticsService.countsAsAppearance)
                    let matchIDs = countableMatches.compactMap(\.id)
                    guard !matchIDs.isEmpty else {
                        return db.eventLoop.makeSucceededFuture([])
                    }

                    var matchByID: [UUID: Match] = [:]
                    for match in countableMatches {
                        if let id = match.id { matchByID[id] = match }
                    }

                    return MatchEvent.query(on: db)
                        .filter(\.$match.$id ~~ matchIDs)
                        .filter(\.$type == eventType)
                        .all()
                        .flatMap { fetchedEvents in
                            let events = fetchedEvents.filter {
                                eventType != .goal || $0.ownGoal != true
                            }
                            let playerIDs = Array(Set(events.compactMap { $0.$player.id }))
                            guard !playerIDs.isEmpty else {
                                return db.eventLoop.makeSucceededFuture([])
                            }

                            return Player.query(on: db)
                                .filter(\.$id ~~ playerIDs)
                                .with(\.$team)
                                .all()
                                .map { players in
                                    var playerByID: [UUID: Player] = [:]
                                    for player in players {
                                        if let id = player.id { playerByID[id] = player }
                                    }
                                    return map(events, matchByID: matchByID, playerByID: playerByID)
                                }
                        }
                }
        }
    }

    private struct Entry {
        var name: String?
        var image: String?
        var number: String?
        var count: Int
        var teamImage: String?
        var teamName: String?
        var teamID: String?
    }

    private static func map(
        _ events: [MatchEvent],
        matchByID: [UUID: Match],
        playerByID: [UUID: Player]
    ) -> [LeaderBoard] {
        var entries: [UUID: Entry] = [:]

        let orderedEvents = events.sorted { lhs, rhs in
            let lhsMatch = matchByID[lhs.$match.id]
            let rhsMatch = matchByID[rhs.$match.id]
            let lhsDate = lhsMatch?.details.date ?? .distantPast
            let rhsDate = rhsMatch?.details.date ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.minute < rhs.minute
        }

        for event in orderedEvents {
            guard let playerID = event.$player.id else { continue }
            let player = playerByID[playerID]
            let match = matchByID[event.$match.id]
            let historicTeam = team(for: event, playerID: playerID, match: match)
            let displayTeam = historicTeam ?? player?.team

            if var existing = entries[playerID] {
                existing.count += 1
                // Prefer the latest event's historic team and
                // fill missing snapshots from the live player record.
                existing.name = event.name ?? existing.name ?? player?.name
                existing.image = event.image ?? existing.image ?? player?.image
                existing.number = event.number ?? existing.number ?? player?.number
                if let displayTeam {
                    existing.teamImage = displayTeam.logo
                    existing.teamName = displayTeam.teamName
                    existing.teamID = displayTeam.id?.uuidString
                }
                entries[playerID] = existing
            } else {
                entries[playerID] = Entry(
                    name: event.name ?? player?.name,
                    image: event.image ?? player?.image,
                    number: event.number ?? player?.number,
                    count: 1,
                    teamImage: displayTeam?.logo,
                    teamName: displayTeam?.teamName,
                    teamID: displayTeam?.id?.uuidString
                )
            }
        }

        return entries.map { playerID, entry in
            LeaderBoard(
                name: entry.name,
                image: entry.image,
                number: entry.number,
                count: Double(entry.count),
                playerid: playerID,
                teamimg: entry.teamImage,
                teamName: entry.teamName,
                teamId: entry.teamID
            )
        }.sorted {
            if ($0.count ?? 0) != ($1.count ?? 0) {
                return ($0.count ?? 0) > ($1.count ?? 0)
            }
            return ($0.name ?? "") < ($1.name ?? "")
        }
    }

    private static func team(for event: MatchEvent, playerID: UUID, match: Match?) -> Team? {
        guard let match else { return nil }
        switch event.assign {
        case .home:
            return match.homeTeam
        case .away:
            return match.awayTeam
        case nil:
            if match.homeBlanket?.players.contains(where: { $0.id == playerID }) == true {
                return match.homeTeam
            }
            if match.awayBlanket?.players.contains(where: { $0.id == playerID }) == true {
                return match.awayTeam
            }
            return nil
        }
    }
}
