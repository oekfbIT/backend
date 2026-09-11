import Fluent
import Vapor

/// Shared, indexed reads and aggregation for every player statistics consumer.
enum PlayerStatisticsService {
    // FieldKey's literal "id" aliases MongoDB's root _id. Codable lineups
    // contain a literal nested "id", so this MUST use .string("id").
    static let homePlayerPath: [FieldKey] = ["homeBlanket", "players", .string("id")]
    static let awayPlayerPath: [FieldKey] = ["awayBlanket", "players", .string("id")]

    struct Snapshot {
        let matches: [Match]
        let events: [MatchEvent]

        func stats(for playerID: UUID, activeLeagueID: UUID? = nil) -> PlayerStatsPair {
            let playerEvents = events.filter { $0.$player.id == playerID }
            let eventIDs = Set(playerEvents.map { $0.$match.id })
            let appearances = matches.filter {
                contains(playerID, in: $0) || $0.id.map(eventIDs.contains) == true
            }
            return makeStats(matches: appearances, events: playerEvents, activeLeagueID: activeLeagueID)
        }
    }

    static func contains(_ playerID: UUID, in match: Match) -> Bool {
        (match.homeBlanket?.players.contains { $0.id == playerID } ?? false)
            || (match.awayBlanket?.players.contains { $0.id == playerID } ?? false)
    }

    static func countsAsAppearance(_ match: Match) -> Bool {
        match.status != .pending && match.status != .cancelled
    }

    /// Query both lineups and event-only participation, across every season and
    /// historical team. No current-team restriction and no collection-wide scan.
    static func load(playerIDs: [UUID], on db: Database) -> EventLoopFuture<Snapshot> {
        let ids = Array(Set(playerIDs))
        guard !ids.isEmpty else {
            return db.eventLoop.makeSucceededFuture(Snapshot(matches: [], events: []))
        }
        let sheets = Match.query(on: db)
            .group(.or) {
                $0.filter(homePlayerPath, .subset(inverse: false), ids)
                $0.filter(awayPlayerPath, .subset(inverse: false), ids)
            }
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$season) { $0.with(\.$league) }
            .all()
        let events = MatchEvent.query(on: db).filter(\.$player.$id ~~ ids).all()
        return sheets.and(events).flatMap { matches, events in
            let knownIDs = Set(matches.compactMap(\.id))
            let missingIDs = Array(Set(events.map { $0.$match.id }).subtracting(knownIDs))
            guard !missingIDs.isEmpty else {
                return db.eventLoop.makeSucceededFuture(Snapshot(matches: matches, events: events))
            }
            // An event can outlive its deleted match. Fetching explicitly avoids
            // an eager-parent failure and excludes that orphan from all totals.
            return Match.query(on: db).filter(\.$id ~~ missingIDs)
                .with(\.$homeTeam)
                .with(\.$awayTeam)
                .with(\.$season) { $0.with(\.$league) }.all()
                .map { Snapshot(matches: matches + $0, events: events) }
        }
    }

    static func calculate(playerID: UUID, activeLeagueID: UUID? = nil, on db: Database) -> EventLoopFuture<PlayerStatsPair> {
        load(playerIDs: [playerID], on: db).map { $0.stats(for: playerID, activeLeagueID: activeLeagueID) }
    }

    static func calculate(playerIDs: [UUID], activeLeagueIDs: [UUID: UUID?] = [:], on db: Database) -> EventLoopFuture<[UUID: PlayerStatsPair]> {
        let ids = Array(Set(playerIDs))
        return load(playerIDs: ids, on: db).map { snapshot in
            // Index once for a whole roster, not one scan/calculation per player.
            let requested = Set(ids)
            var matchesByPlayer = [UUID: [UUID: Match]]()
            var eventsByPlayer = [UUID: [MatchEvent]]()
            let matchesByID = Dictionary(snapshot.matches.compactMap { m in m.id.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
            for match in snapshot.matches {
                guard let matchID = match.id else { continue }
                let participants = Set((match.homeBlanket?.players.map(\.id) ?? []) + (match.awayBlanket?.players.map(\.id) ?? []))
                for id in participants.intersection(requested) { matchesByPlayer[id, default: [:]][matchID] = match }
            }
            for event in snapshot.events {
                guard let id = event.$player.id, requested.contains(id) else { continue }
                eventsByPlayer[id, default: []].append(event)
                if let match = matchesByID[event.$match.id] { matchesByPlayer[id, default: [:]][event.$match.id] = match }
            }
            return Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, makeStats(matches: Array(matchesByPlayer[id, default: [:]].values), events: eventsByPlayer[id, default: []], activeLeagueID: activeLeagueIDs[id] ?? nil))
            })
        }
    }

    static func emptyStats() -> PlayerStats {
        PlayerStats(matchesPlayed: 0, goalsScored: 0, redCards: 0, yellowCards: 0, yellowRedCrd: 0, goalsAverage: nil)
    }

    static func makeStats(matches: [Match], events: [MatchEvent], activeLeagueID: UUID?) -> PlayerStatsPair {
        let played = matches.filter(countsAsAppearance)
        let allIDs = Set(played.compactMap(\.id))
        let activeIDs = Set(played.filter {
            $0.season?.primary == true && (activeLeagueID == nil || $0.season?.$league.id == activeLeagueID)
        }.compactMap(\.id))
        var all = emptyStats(), season = emptyStats()
        all.matchesPlayed = allIDs.count
        season.matchesPlayed = activeIDs.count
        var seenEvents = Set<UUID>()
        for event in events where allIDs.contains(event.$match.id) {
            if let id = event.id, !seenEvents.insert(id).inserted { continue }
            add(event, to: &all)
            if activeIDs.contains(event.$match.id) { add(event, to: &season) }
        }
        all.goalsAverage = all.matchesPlayed > 0 ? Double(all.goalsScored) / Double(all.matchesPlayed) : nil
        season.goalsAverage = season.matchesPlayed > 0 ? Double(season.goalsScored) / Double(season.matchesPlayed) : nil
        return PlayerStatsPair(all: all, season: season)
    }

    private static func add(_ event: MatchEvent, to stats: inout PlayerStats) {
        switch event.type {
        case .goal where event.ownGoal != true: stats.goalsScored += 1
        case .redCard: stats.redCards += 1
        case .yellowCard: stats.yellowCards += 1
        case .yellowRedCard: stats.yellowRedCrd += 1
        default: break
        }
    }
}

/// League leaderboards are scoped by the seasons/matches belonging to a league,
/// not by a player's current team. This keeps transferred players and historic
/// events in the correct league.
enum LeaderboardService {
    static func fetch(
        leagueID: UUID?,
        eventType: MatchEventType,
        primaryOnly: Bool,
        on db: Database
    ) -> EventLoopFuture<[LeaderBoard]> {
        var seasonQuery = Season.query(on: db)
        if let leagueID { seasonQuery = seasonQuery.filter(\.$league.$id == leagueID) }
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

    static func map(
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
            if lhs.minute != rhs.minute { return lhs.minute < rhs.minute }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }

        var seenEvents = Set<UUID>()
        for event in orderedEvents {
            if let id = event.id, !seenEvents.insert(id).inserted { continue }
            guard !(event.type == .goal && event.ownGoal == true), let recordedMatch = matchByID[event.$match.id],
                  PlayerStatisticsService.countsAsAppearance(recordedMatch) else { continue }
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
            if ($0.name ?? "") != ($1.name ?? "") { return ($0.name ?? "") < ($1.name ?? "") }
            return ($0.playerid?.uuidString ?? "") < ($1.playerid?.uuidString ?? "")
        }
    }

    private static func team(for event: MatchEvent, playerID: UUID, match: Match?) -> Team? {
        guard let match else { return nil }
        switch TeamStatisticsService.assignment(for: event, in: match) {
        case .home: return match.homeTeam
        case .away: return match.awayTeam
        case nil: return nil
        }
    }
}
