import Fluent
import Foundation
import Vapor

protocol CommentaryContextProviding {
    func matchPreview(_ id: UUID, now: Date) async throws -> CommentaryContext
    func matchPreviews(_ ids: [UUID], now: Date) async -> [(UUID, Result<CommentaryContext, Error>)]
    func gameDaySummary(_ seasonID: UUID, gameday: Int, allowPartial: Bool, now: Date) async throws -> CommentaryContext
}

extension CommentaryContextProviding {
    func matchPreviews(_ ids: [UUID], now: Date) async -> [(UUID, Result<CommentaryContext, Error>)] {
        var results = [(UUID, Result<CommentaryContext, Error>)]()
        for id in ids {
            do { results.append((id, .success(try await matchPreview(id, now: now)))) }
            catch { results.append((id, .failure(error))) }
        }
        return results
    }
}

/// One season read feeds form, splits, standings and scorer calculations; no HTTP fan-out.
struct CommentarySeasonData {
    let season: Season
    let league: League
    let teams: [Team]
    let matches: [Match]
    let players: [Player]
}

struct CommentaryContextBuilder: CommentaryContextProviding {
    let database: Database

    func matchPreviews(_ ids: [UUID], now: Date) async -> [(UUID, Result<CommentaryContext, Error>)] {
        do {
            let fixtures = try await Match.query(on: database).filter(\.$id ~~ ids).all()
            let teamIDs = Set(fixtures.flatMap { [$0.$homeTeam.id, $0.$awayTeam.id] })
            let meetings = teamIDs.isEmpty ? [] : try await Match.query(on: database)
                .filter(\.$homeTeam.$id ~~ Array(teamIDs)).filter(\.$awayTeam.$id ~~ Array(teamIDs))
                .filter(Match.FieldKeys.date, .lessThan, now).sort(Match.FieldKeys.date, .descending).limit(5000).all()
            let players = teamIDs.isEmpty ? [] : try await Player.query(on: database).filter(\.$team.$id ~~ Array(teamIDs)).all()
            var seasons = [UUID: CommentarySeasonData]()
            var output = [(UUID, Result<CommentaryContext, Error>)]()
            for id in ids {
                do {
                    guard let match = fixtures.first(where: { $0.id == id }), let seasonID = match.$season.id else {
                        throw Abort(.notFound, reason: "Match or season not found.")
                    }
                    if seasons[seasonID] == nil {
                        let base = try await loadSeason(seasonID)
                        seasons[seasonID] = .init(season: base.season, league: base.league, teams: base.teams, matches: base.matches, players: players)
                    }
                    let h2h = meetings.filter { ($0.$homeTeam.id == match.$homeTeam.id && $0.$awayTeam.id == match.$awayTeam.id) || ($0.$homeTeam.id == match.$awayTeam.id && $0.$awayTeam.id == match.$homeTeam.id) }
                    output.append((id, .success(try Self.preview(match: match, data: seasons[seasonID]!, meetings: h2h, now: now))))
                } catch { output.append((id, .failure(error))) }
            }
            return output
        } catch { return ids.map { ($0, .failure(error)) } }
    }

    func loadSeason(_ id: UUID, includePlayers: Bool = false) async throws -> CommentarySeasonData {
        guard let season = try await Season.find(id, on: database),
              let league = try await season.$league.get(on: database) else {
            throw Abort(.notFound, reason: "Season or its league was not found.")
        }
        let matches = try await Match.query(on: database).filter(\.$season.$id == id)
            .with(\.$events).all()
        let entries = try await SeasonTeam.query(on: database).filter(\.$season.$id == id).all()
        var teamIDs = Set(entries.map { $0.$team.id })
        matches.forEach { teamIDs.insert($0.$homeTeam.id); teamIDs.insert($0.$awayTeam.id) }
        let teams = teamIDs.isEmpty ? [] : try await Team.query(on: database).filter(\.$id ~~ Array(teamIDs)).all()
        let players = !includePlayers || teamIDs.isEmpty ? [] : try await Player.query(on: database)
            .filter(\.$team.$id ~~ Array(teamIDs)).all()
        return .init(season: season, league: league, teams: teams, matches: matches, players: players)
    }

    func matchPreview(_ id: UUID, now: Date = Date()) async throws -> CommentaryContext {
        guard let match = try await Match.find(id, on: database), let seasonID = match.$season.id else {
            throw Abort(.notFound, reason: "Match or its season was not found.")
        }
        guard let kickoff = match.details.date else {
            throw Abort(.unprocessableEntity, reason: "A reliable kickoff is required to prevent future-result leakage.")
        }
        let data = try await loadSeason(seasonID, includePlayers: kickoff > now && match.status == .pending)
        let cutoff = min(kickoff, now)
        let h2h = try await Match.query(on: database)
            .group(.or) { q in
                q.group(.and) { $0.filter(\.$homeTeam.$id == match.$homeTeam.id).filter(\.$awayTeam.$id == match.$awayTeam.id) }
                q.group(.and) { $0.filter(\.$homeTeam.$id == match.$awayTeam.id).filter(\.$awayTeam.$id == match.$homeTeam.id) }
            }
            .filter(Match.FieldKeys.date, .lessThan, cutoff)
            .sort(Match.FieldKeys.date, .descending).limit(50).all()
        return try Self.preview(match: match, data: data, meetings: h2h, now: now)
    }

    func gameDaySummary(_ seasonID: UUID, gameday: Int, allowPartial: Bool, now: Date = Date()) async throws -> CommentaryContext {
        let data = try await loadSeason(seasonID)
        return try Self.summary(data: data, gameday: gameday, allowPartial: allowPartial, now: now)
    }

    /// A recorded end time is preferred. Undated results and fixtures which might still be playing
    /// are omitted. This is recorded chronology, not a reconstruction of old database revisions.
    static func resultKnown(_ match: Match, before cutoff: Date) -> Bool {
        guard TeamStatisticsService.countsAsResult(match), match.status != .abbgebrochen,
              let kickoff = match.details.date, kickoff < cutoff else { return false }
        if let ended = match.secondHalfEndDate { return ended >= kickoff && ended <= cutoff }
        return kickoff.addingTimeInterval(6 * 3600) <= cutoff
    }

    static func ordered(_ matches: [Match]) -> [Match] {
        matches.sorted {
            let a = $0.details.date ?? .distantPast, b = $1.details.date ?? .distantPast
            return a != b ? a > b : ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }
    }

    static func name(_ id: UUID, in data: CommentarySeasonData, fallback: String? = nil) -> String {
        data.teams.first { $0.id == id }?.teamName ?? fallback ?? "Team \(id.uuidString.prefix(8))"
    }

    static func dateText(_ date: Date, time: Bool = false, matchClock: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        // Match dates contain the admin's wall-clock fields under a UTC suffix.
        // Actual timestamps (for example suspension expiry) still use Vienna time.
        formatter.timeZone = matchClock ? TimeZone(secondsFromGMT: 0)! : TimeZone(identifier: "Europe/Vienna")!
        formatter.dateFormat = time ? "dd.MM.yyyy 'um' HH:mm 'Uhr'" : "dd.MM.yyyy"
        return formatter.string(from: date)
    }

    static func preview(match: Match, data: CommentarySeasonData, meetings: [Match], now: Date) throws -> CommentaryContext {
        guard let id = match.id, let seasonID = data.season.id, match.$season.id == seasonID,
              let kickoff = match.details.date else { throw Abort(.unprocessableEntity, reason: "Incomplete fixture context.") }
        let historical = kickoff <= now || match.status != .pending
        let cutoff = min(kickoff, now)
        let previous = ordered(data.matches.filter { $0.id != id && resultKnown($0, before: cutoff) })
        let home = name(match.$homeTeam.id, in: data, fallback: match.homeBlanket?.name)
        let away = name(match.$awayTeam.id, in: data, fallback: match.awayBlanket?.name)
        var facts = [CommentaryFact]()
        func add(_ key: String, _ group: String, _ text: String, _ sources: [String]) {
            facts.append(.init(id: key, group: group, text: text, sourceIDs: sources.sorted()))
        }
        add("fixture", "opening", historical
            ? "Die Ausgangslage vor dem Duell zwischen \(home) und \(away) am \(match.details.gameday). Spieltag der \(data.league.name) steht im Mittelpunkt dieses historischen Vorberichts."
            : "\(home) gegen \(away): Am \(match.details.gameday). Spieltag der \(data.league.name) treffen die beiden Teams aufeinander.", [id.uuidString, seasonID.uuidString])
        add("schedule", "opening", historical
            ? "Als Spieltermin ist der \(dateText(kickoff, time: true, matchClock: true)) verzeichnet."
            : "Anpfiff ist am \(dateText(kickoff, time: true, matchClock: true)).", [id.uuidString])
        if let location = match.details.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            add("venue", "opening", "Spielort: \(location).", [id.uuidString])
        }
        let table = TeamStatisticsService.table(teams: data.teams, matches: previous)
        if !historical { facts += tableStakes(match: match, table: table, fixtures: data.matches, previous: previous, now: now) }
        let race = scorerRace(previous)
        let unavailable = Set(data.players.filter {
            !historical && $0.eligibility == .Gesperrt && ($0.blockdate.map { $0 > kickoff } ?? false)
        }.compactMap(\.id))
        for (label, teamID, teamName, atHome) in [("home", match.$homeTeam.id, home, true), ("away", match.$awayTeam.id, away, false)] {
            facts += teamFacts(teamID: teamID, teamName: teamName, matches: previous, label: label, atHome: atHome)
            if let row = table.first(where: { $0.id == teamID }), !previous.isEmpty {
                add("\(label).table", label, "\(teamName) steht mit \(row.points) Punkten auf Platz \(row.ranking).", previous.compactMap { $0.id?.uuidString })
            }
            facts += scorerFacts(teamID: teamID, teamName: teamName, matches: previous, label: label, players: data.players, excludedPlayers: unavailable)
            facts += playerAngles(teamID: teamID, teamName: teamName, matches: previous, players: data.players, label: label, race: race, excludedPlayers: unavailable)
            if !historical {
                facts += suspensionFacts(teamID: teamID, teamName: teamName, players: data.players, matches: previous,
                                         kickoff: kickoff, matchID: id, label: label)
            }
        }
        let pastMeetings = ordered(meetings.filter { $0.id != id && resultKnown($0, before: cutoff) }).prefix(5)
        if !pastMeetings.isEmpty {
            for (index, old) in pastMeetings.enumerated() {
                let h = old.$homeTeam.id == match.$homeTeam.id ? home : away
                let a = old.$awayTeam.id == match.$awayTeam.id ? away : home
                add("h2h.\(index)", "history", resultSentence(old, home: h, away: a), [old.id!.uuidString])
            }
        }
        if let h = table.first(where: { $0.id == match.$homeTeam.id }), let a = table.first(where: { $0.id == match.$awayTeam.id }), !previous.isEmpty {
            add("gap", "closing", "In der Tabelle trennen \(home) und \(away) \(abs(h.points - a.points)) Punkte.", previous.compactMap { $0.id?.uuidString })
        }
        if let outlook = goalOutlook(homeID: match.$homeTeam.id, awayID: match.$awayTeam.id, matches: previous, historical: historical) { facts.append(outlook) }
        let tableContext = facts.first { $0.id.hasSuffix(".stakes") } ?? facts.first { $0.id.hasSuffix(".table") }
        return .init(kind: .matchPreview, targetKey: "match:\(id)", seasonID: seasonID, matchID: id,
            gameday: match.details.gameday, cutoff: cutoff, historical: historical, partial: false,
            leagueCode: data.league.code ?? "", titles: [historical ? "\(home) gegen \(away): die Ausgangslage vor dem Spiel" : "\(home) gegen \(away): der Vorbericht"],
            facts: facts, requiredFactIDs: ["fixture"] + facts.filter {
                $0.id.hasSuffix(".suspended.summary") || $0.id.hasSuffix(".defence_trend") || $0.id == "goal_outlook"
            }.map(\.id) + (tableContext.map { [$0.id] } ?? []), warnings: historical
                ? ["Historische Sperren und aktuelle Kaderzuordnungen werden nicht rückwirkend behauptet.", "Datenkorrekturen nach dem Stichtag lassen sich ohne frühere Datenbank-Snapshots nicht rekonstruieren."]
                : ["Unbekannte Verletzungen und unbestätigte Aufstellungen werden nicht behauptet.", "Torjäger-Meilensteine setzen vollständig zuordenbare Torereignisse voraus; Freistöße und Strafstöße sind keine Foulstatistik."])
    }

    static func teamFacts(teamID: UUID, teamName: String, matches: [Match], label: String, atHome: Bool) -> [CommentaryFact] {
        let all = ordered(matches.filter { $0.$homeTeam.id == teamID || $0.$awayTeam.id == teamID })
        guard !all.isEmpty else { return [] }
        var facts = [CommentaryFact]()
        func add(_ key: String, _ text: String, _ source: [Match]) {
            facts.append(.init(id: "\(label).\(key)", group: label, text: text, sourceIDs: source.compactMap { $0.id?.uuidString }.sorted()))
        }
        let recent = Array(all.prefix(5)), results = TeamStatisticsService.aggregate(teamID: teamID, matches: recent)
        let played = recent.filter { $0.status != .cancelled }
        let stats = TeamStatisticsService.aggregate(teamID: teamID, matches: played)
        let awarded = recent.count - played.count
        let trend = defensiveTrend(teamID: teamID, teamName: teamName, matches: all, label: label)
        let record = "\(results.wins)–\(results.draws)–\(results.losses) (S–U–N\(awarded > 0 ? ", inkl. \(awarded) Wertung" : ""))"
        if awarded > 0 {
            let goals = played.isEmpty ? "" : " In \(played.count) gespielten Partien fielen \(stats.totalScored):\(stats.totalAgainst) Tore."
            let caution = trend == nil && played.count >= 3 && stats.totalAgainst >= 3 * played.count ? " Die Defensive bleibt dabei eine Baustelle." : ""
            add("form", "\(teamName): Die jüngste Ergebnisbilanz lautet \(record).\(goals)\(caution)", recent)
        } else if trend != nil {
            // The required trend already explains the defence. Do not repeat five-game
            // defensive totals or generic weakness claims in the accompanying form sentence.
            if recent.count >= 3 && stats.totalScored >= 3 * recent.count {
                add("form", "Vorne liefert \(teamName): \(stats.totalScored) Tore in den letzten \(recent.count) Spielen bei einer Bilanz von \(record).", recent)
            } else {
                add("form", "Die jüngste Ergebnisbilanz von \(teamName) lautet \(record).", recent)
            }
        } else if recent.count >= 3 && stats.totalScored >= 3 * recent.count && stats.totalScored >= stats.totalAgainst {
            let caution = stats.totalAgainst >= 3 * recent.count ? " Allerdings blieb die Defensive mit \(stats.totalAgainst) Gegentoren anfällig." : ""
            add("form", "Die Offensive von \(teamName) läuft: \(stats.totalScored) Tore in den letzten \(recent.count) Spielen bei einer Bilanz von \(record).\(caution)", recent)
        } else if recent.count >= 3 && stats.totalAgainst >= 3 * recent.count {
            let attack = stats.totalScored >= 3 * recent.count ? " Vorne gelangen immerhin \(stats.totalScored) Tore." : ""
            add("form", "\(teamName) hat vor allem hinten eine Baustelle: \(stats.totalAgainst) Gegentore in den letzten \(recent.count) Spielen, die Bilanz steht bei \(record).\(attack)", recent)
        } else {
            add("form", "\(teamName) kommt aus den letzten \(recent.count) Spielen mit einer Bilanz von \(record) und \(stats.totalScored):\(stats.totalAgainst) Toren.", recent)
        }
        let split = all.filter { atHome ? $0.$homeTeam.id == teamID : $0.$awayTeam.id == teamID }
        if !split.isEmpty {
            let s = TeamStatisticsService.aggregate(teamID: teamID, matches: split)
            let playedSplit = split.filter { $0.status != .cancelled }
            let g = TeamStatisticsService.aggregate(teamID: teamID, matches: playedSplit)
            if playedSplit.count != split.count {
                add("split", "\(atHome ? "Zu Hause" : "Auswärts") lautet die Ergebnisbilanz von \(teamName) \(s.wins)–\(s.draws)–\(s.losses) (S–U–N, inkl. Wertungen); die \(playedSplit.count) gespielten Partien brachten \(g.totalScored):\(g.totalAgainst) Tore.", split)
            } else {
                add("split", "\(atHome ? "Zu Hause" : "Auswärts") steht \(teamName) bei \(s.wins)–\(s.draws)–\(s.losses) (S–U–N) und \(s.totalScored):\(s.totalAgainst) Toren aus \(split.count) Spielen.", split)
            }
        }
        if trend == nil && played.count >= 3 && stats.totalAgainst >= 3 * played.count {
            add("defence", "Die Defensive von \(teamName) bleibt eine Baustelle: In den letzten \(played.count) gespielten Partien fielen \(stats.totalAgainst) Gegentore.", played)
        }
        if played.count >= 3 && stats.totalScored >= 3 * played.count {
            add("attack", "Torgefahr bringt \(teamName) mit: \(stats.totalScored) Treffer in den letzten \(played.count) gespielten Partien sprechen für die Offensive.", played)
        }
        let unbeaten = all.prefix { m in m.$homeTeam.id == teamID ? m.score.home >= m.score.away : m.score.away >= m.score.home }
        if unbeaten.count >= 2 { add("streak", "\(teamName) ist seit \(unbeaten.count) Spielen ungeschlagen.", Array(unbeaten)) }
        else {
            let lost = all.prefix { m in m.$homeTeam.id == teamID ? m.score.home < m.score.away : m.score.away < m.score.home }
            if lost.count >= 2 { add("streak", "Nach \(lost.count) Niederlagen in Folge steht \(teamName) unter Druck.", Array(lost)) }
        }
        if let last = all.first { add("last", resultSentence(last, home: last.$homeTeam.id == teamID ? teamName : (last.homeBlanket?.name ?? "das Heimteam"), away: last.$awayTeam.id == teamID ? teamName : (last.awayBlanket?.name ?? "das Auswärtsteam")), [last]) }
        if let trend { facts.append(trend) }
        return facts
    }

    static func scorerFacts(teamID: UUID, teamName: String, matches: [Match], label: String,
                            players: [Player] = [], excludedPlayers: Set<UUID> = []) -> [CommentaryFact] {
        var counts = [String: (String, Int, Set<String>)]()
        for match in matches where match.status != .cancelled {
            guard match.$homeTeam.id == teamID || match.$awayTeam.id == teamID else { continue }
            let side: MatchAssignment = match.$homeTeam.id == teamID ? .home : .away
            var seen = Set<UUID>()
            for event in match.$events.value ?? [] where event.type == .goal && event.ownGoal != true {
                if let id = event.id, !seen.insert(id).inserted { continue }
                guard TeamStatisticsService.scoringAssignment(for: event, in: match) == side else { continue }
                guard let playerID = event.$player.id else { continue }
                guard !excludedPlayers.contains(playerID), players.first(where: { $0.id == playerID }).map({ $0.$team.id == teamID }) ?? true else { continue }
                let sheet = side == .home ? match.homeBlanket : match.awayBlanket
                guard let playerName = event.name ?? sheet?.players.first(where: { $0.id == playerID })?.name, !playerName.isEmpty else { continue }
                let key = playerID.uuidString
                var row = counts[key] ?? (playerName, 0, [])
                row.1 += 1
                row.2.insert(match.id!.uuidString)
                if let eventID = event.id { row.2.insert(eventID.uuidString) }
                counts[key] = row
            }
        }
        return counts.sorted { $0.value.1 != $1.value.1 ? $0.value.1 > $1.value.1 : $0.key < $1.key }.prefix(3).map { key, row in
            CommentaryFact(id: "\(label).scorer.\(key)", group: label,
                text: "Im Angriff von \(teamName) fällt \(row.0.trimmingCharacters(in: .whitespacesAndNewlines)) auf: Er traf bereits \(row.1)-mal.", sourceIDs: row.2.sorted())
        }
    }

    static func resultSentence(_ match: Match, home: String, away: String) -> String {
        let date = match.details.date.map { "Am \(dateText($0, matchClock: true)) " } ?? ""
        if match.status == .cancelled {
            return "\(date)wurde die Begegnung \(home) gegen \(away) mit \(match.score.home):\(match.score.away) gewertet; dieses Ergebnis wird nicht als auf dem Platz erzielter Spielverlauf beschrieben."
        }
        return "\(date)endete die Begegnung zwischen \(home) und \(away) mit \(match.score.home):\(match.score.away)."
    }

    static func summary(data: CommentarySeasonData, gameday: Int, allowPartial: Bool, now: Date) throws -> CommentaryContext {
        try weeklySummary(data: data, gameday: gameday, allowPartial: allowPartial, now: now)
    }
}
