import Fluent
import Vapor

/// Team results, cards, form and standings share the same match policy.
enum TeamStatisticsService {
    static func countsAsResult(_ match: Match) -> Bool {
        switch match.status {
        case .pending, .first, .halftime, .second: return false
        // The no-show routes award 6–0 with status `cancelled`. Preserve the
        // awarded result, without turning an unplayed 0–0 cancellation into a draw.
        case .cancelled: return match.score.home != 0 || match.score.away != 0
        case .completed, .submitted, .done, .abbgebrochen: return true
        }
    }

    static func emptyStats() -> TeamStats {
        TeamStats(wins: 0, draws: 0, losses: 0, totalScored: 0, totalAgainst: 0,
                  goalDifference: 0, totalPoints: 0, totalYellowCards: 0, totalRedCards: 0)
    }

    /// Never attribute a historic card using a player's CURRENT team (or by
    /// comparing a player UUID with a team UUID). Ambiguous legacy events stay unassigned.
    static func assignment(for event: MatchEvent, in match: Match) -> MatchAssignment? {
        if let assignment = event.assign { return assignment }
        guard let id = event.$player.id else { return nil }
        let home = match.homeBlanket?.players.contains { $0.id == id } ?? false
        let away = match.awayBlanket?.players.contains { $0.id == id } ?? false
        guard home != away else { return nil }
        return home ? .home : .away
    }

    static func scoringAssignment(for event: MatchEvent, in match: Match) -> MatchAssignment? {
        // Goal-entry clients use assign for the team RECEIVING the goal.
        if let assign = event.assign { return assign }
        guard let playerSide = assignment(for: event, in: match) else { return nil }
        return event.ownGoal == true ? (playerSide == .home ? .away : .home) : playerSide
    }

    static func removeCardFromSheet(_ event: MatchEvent, match: Match) {
        guard let id = event.$player.id, let side = assignment(for: event, in: match) else { return }
        guard var sheet = side == .home ? match.homeBlanket : match.awayBlanket,
              let index = sheet.players.firstIndex(where: { $0.id == id }) else { return }
        switch event.type {
        case .yellowCard: sheet.players[index].yellowCard = max(0, (sheet.players[index].yellowCard ?? 0) - 1)
        case .redCard: sheet.players[index].redCard = max(0, (sheet.players[index].redCard ?? 0) - 1)
        case .yellowRedCard: sheet.players[index].redYellowCard = max(0, (sheet.players[index].redYellowCard ?? 0) - 1)
        default: return
        }
        if side == .home { match.homeBlanket = sheet } else { match.awayBlanket = sheet }
    }

    static func aggregate(teamID: UUID, matches: [Match]) -> TeamStats {
        var stats = emptyStats()
        var seenMatches = Set<UUID>()
        for match in matches {
            guard match.$homeTeam.id == teamID || match.$awayTeam.id == teamID else { continue }
            if let id = match.id, !seenMatches.insert(id).inserted { continue }
            let home = match.$homeTeam.id == teamID
            if countsAsResult(match) {
                let scored = home ? match.score.home : match.score.away
                let against = home ? match.score.away : match.score.home
                stats.totalScored += scored
                stats.totalAgainst += against
                if scored > against { stats.wins += 1 }
                else if scored == against { stats.draws += 1 }
                else { stats.losses += 1 }
            }
            guard PlayerStatisticsService.countsAsAppearance(match) else { continue }
            var seenEvents = Set<UUID>()
            for event in match.$events.value ?? [] {
                if let id = event.id, !seenEvents.insert(id).inserted { continue }
                guard let side = assignment(for: event, in: match), side == (home ? .home : .away) else { continue }
                switch event.type {
                case .yellowCard: stats.totalYellowCards += 1
                case .redCard: stats.totalRedCards += 1
                case .yellowRedCard: stats.totalYellowRedCards += 1
                default: break
                }
            }
        }
        stats.goalDifference = stats.totalScored - stats.totalAgainst
        stats.totalPoints = 3 * stats.wins + stats.draws
        let played = stats.wins + stats.draws + stats.losses
        stats.avgGoals = played > 0 ? Double(stats.totalScored) / Double(played) : nil
        return stats
    }

    static func calculate(teamIDs: [UUID], primaryOnly: Bool = false, on db: Database) -> EventLoopFuture<[UUID: TeamStatsPair]> {
        let ids = Array(Set(teamIDs))
        guard !ids.isEmpty else { return db.eventLoop.makeSucceededFuture([:]) }
        let teamsF = Team.query(on: db).filter(\.$id ~~ ids).all()
        let query = Match.query(on: db)
            .group(.or) {
                $0.filter(\.$homeTeam.$id ~~ ids)
                $0.filter(\.$awayTeam.$id ~~ ids)
            }
            .with(\.$season).with(\.$events)
        let matchesF: EventLoopFuture<[Match]>
        if primaryOnly {
            matchesF = Season.query(on: db).filter(\.$primary == true).all(\.$id).flatMap { seasonIDs in
                guard !seasonIDs.isEmpty else { return db.eventLoop.makeSucceededFuture([]) }
                return query.filter(\.$season.$id ~~ seasonIDs).all()
            }
        } else {
            matchesF = query.all()
        }
        return teamsF.and(matchesF).map { teams, matches in
            let leagues = Dictionary(teams.compactMap { t in t.id.map { ($0, t.$league.id) } }, uniquingKeysWith: { a, _ in a })
            var byTeam = [UUID: [Match]]()
            for match in matches {
                byTeam[match.$homeTeam.id, default: []].append(match)
                if match.$awayTeam.id != match.$homeTeam.id { byTeam[match.$awayTeam.id, default: []].append(match) }
            }
            return Dictionary(uniqueKeysWithValues: ids.map { id in
                let all = byTeam[id, default: []]
                let active = all.filter {
                    $0.season?.primary == true && $0.season?.$league.id == (leagues[id] ?? nil)
                }
                return (id, TeamStatsPair(all: aggregate(teamID: id, matches: all), season: aggregate(teamID: id, matches: active)))
            })
        }
    }

    static func recentForm(teamID: UUID, matches: [Match]) -> [FormItem] {
        let relevant = matches.filter { ($0.$homeTeam.id == teamID || $0.$awayTeam.id == teamID) && countsAsResult($0) }
        return relevant.sorted {
            let lhs = $0.details.date ?? .distantPast, rhs = $1.details.date ?? .distantPast
            return lhs != rhs ? lhs > rhs : ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }.prefix(5).compactMap { match in
            guard let id = match.id else { return nil }
            let home = match.$homeTeam.id == teamID
            let mine = home ? match.score.home : match.score.away
            let opponent = home ? match.score.away : match.score.home
            return FormItem(result: mine == opponent ? .D : (mine > opponent ? .W : .L),
                            matchID: id, gameday: match.details.gameday, score: match.score,
                            home: match.homeBlanket?.name, away: match.awayBlanket?.name, date: match.details.date)
        }
    }

    static func table(teams: [Team], matches: [Match]) -> [TableItem] {
        var rows = teams.compactMap { team -> TableItem? in
            guard let id = team.id else { return nil }
            let stats = aggregate(teamID: id, matches: matches)
            return TableItem(image: team.logo, name: team.teamName, points: stats.totalPoints, id: id,
                             goals: stats.totalScored, ranking: 0, wins: stats.wins, draws: stats.draws,
                             losses: stats.losses, scored: stats.totalScored, against: stats.totalAgainst,
                             difference: stats.goalDifference, form: recentForm(teamID: id, matches: matches))
        }
        rows.sort {
            if $0.points != $1.points { return $0.points > $1.points }
            if $0.difference != $1.difference { return $0.difference > $1.difference }
            if $0.scored != $1.scored { return $0.scored > $1.scored }
            return $0.id.uuidString < $1.id.uuidString
        }
        for index in rows.indices { rows[index].ranking = index + 1 }
        return rows
    }

    static func table(leagueID: UUID, primaryOnly: Bool, on db: Database) -> EventLoopFuture<[TableItem]> {
        var seasons = Season.query(on: db).filter(\.$league.$id == leagueID)
        if primaryOnly { seasons = seasons.filter(\.$primary == true) }
        let teamsF = Team.query(on: db).filter(\.$league.$id == leagueID).all()
        return seasons.all(\.$id).and(teamsF).flatMap { ids, teams in
            guard !ids.isEmpty else { return db.eventLoop.makeSucceededFuture(table(teams: teams, matches: [])) }
            return Match.query(on: db).filter(\.$season.$id ~~ ids).all()
                .map { table(teams: teams, matches: $0) }
        }
    }
}
