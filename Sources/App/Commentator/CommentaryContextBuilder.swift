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

    static func dateText(_ date: Date, time: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.timeZone = TimeZone(identifier: "Europe/Vienna")!
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
            : "Am \(match.details.gameday). Spieltag der \(data.league.name) treffen \(home) und \(away) aufeinander; die bisherigen Ergebnisse liefern den Rahmen für dieses Duell.", [id.uuidString, seasonID.uuidString])
        add("schedule", "opening", historical
            ? "Als Spieltermin ist der \(dateText(kickoff, time: true)) verzeichnet."
            : "Angesetzt ist die Begegnung für den \(dateText(kickoff, time: true)).", [id.uuidString])
        if let location = match.details.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            add("venue", "opening", "Als Spielort ist \(location) eingetragen.", [id.uuidString])
        }
        let table = TeamStatisticsService.table(teams: data.teams, matches: previous)
        for (label, teamID, teamName, atHome) in [("home", match.$homeTeam.id, home, true), ("away", match.$awayTeam.id, away, false)] {
            facts += teamFacts(teamID: teamID, teamName: teamName, matches: previous, label: label, atHome: atHome)
            if let row = table.first(where: { $0.id == teamID }), !previous.isEmpty {
                add("\(label).table", label, "\(teamName) liegt in der aus den berücksichtigten Ergebnissen berechneten Tabelle mit \(row.points) Punkten auf Rang \(row.ranking).", previous.compactMap { $0.id?.uuidString })
            }
            facts += scorerFacts(teamID: teamID, teamName: teamName, matches: previous, label: label)
            if !historical {
                for player in data.players.filter({ $0.$team.id == teamID && $0.eligibility == .Gesperrt && ($0.blockdate.map { $0 >= kickoff } ?? false) }).sorted(by: { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }) {
                    guard let playerID = player.id, let until = player.blockdate else { continue }
                    add("\(label).suspended.\(playerID)", label, "Bei \(teamName) ist \(player.name) laut aktuellem Spielerregister bis \(dateText(until, time: true)) gesperrt; der eingetragene Sperrzeitraum umfasst den Anpfiff.", [playerID.uuidString, id.uuidString])
                }
            }
        }
        let pastMeetings = ordered(meetings.filter { $0.id != id && resultKnown($0, before: cutoff) }).prefix(5)
        if !pastMeetings.isEmpty {
            add("h2h.count", "history", "Für den direkten Vergleich liegen \(pastMeetings.count) berücksichtigte frühere Begegnungen vor; ältere oder unvollständig datierte Spiele sind darin nicht zwingend enthalten.", pastMeetings.compactMap { $0.id?.uuidString })
            for (index, old) in pastMeetings.enumerated() {
                let h = old.$homeTeam.id == match.$homeTeam.id ? home : away
                let a = old.$awayTeam.id == match.$awayTeam.id ? away : home
                add("h2h.\(index)", "history", resultSentence(old, home: h, away: a), [old.id!.uuidString])
            }
        }
        if let h = table.first(where: { $0.id == match.$homeTeam.id }), let a = table.first(where: { $0.id == match.$awayTeam.id }), !previous.isEmpty {
            add("gap", "closing", "Zwischen den beiden Mannschaften liegen nach den berücksichtigten Saisonergebnissen \(abs(h.points - a.points)) Punkte; damit liefert auch die Tabellensituation einen konkreten Bezugspunkt für das Aufeinandertreffen.", previous.compactMap { $0.id?.uuidString })
        }
        return .init(kind: .matchPreview, targetKey: "match:\(id)", seasonID: seasonID, matchID: id,
            gameday: match.details.gameday, cutoff: cutoff, historical: historical, partial: false,
            leagueCode: data.league.code ?? "", titles: [historical ? "\(home) gegen \(away): die Ausgangslage vor dem Spiel" : "\(home) gegen \(away): der Vorbericht"],
            facts: facts, requiredFactIDs: ["fixture"], warnings: historical
                ? ["Historische Sperren und aktuelle Kaderzuordnungen werden nicht rückwirkend behauptet.", "Datenkorrekturen nach dem Stichtag lassen sich ohne frühere Datenbank-Snapshots nicht rekonstruieren."]
                : ["Unbekannte Verletzungen und unbestätigte Aufstellungen werden nicht behauptet."])
    }

    static func teamFacts(teamID: UUID, teamName: String, matches: [Match], label: String, atHome: Bool) -> [CommentaryFact] {
        let all = ordered(matches.filter { $0.$homeTeam.id == teamID || $0.$awayTeam.id == teamID })
        guard !all.isEmpty else { return [] }
        var facts = [CommentaryFact]()
        func add(_ key: String, _ text: String, _ source: [Match]) {
            facts.append(.init(id: "\(label).\(key)", group: label, text: text, sourceIDs: source.compactMap { $0.id?.uuidString }.sorted()))
        }
        let recent = Array(all.prefix(5)), stats = TeamStatisticsService.aggregate(teamID: teamID, matches: recent)
        add("form", "Aus den letzten \(recent.count) berücksichtigten Partien nimmt \(teamName) \(stats.wins) \(stats.wins == 1 ? "Sieg" : "Siege"), \(stats.draws) Unentschieden und \(stats.losses) \(stats.losses == 1 ? "Niederlage" : "Niederlagen") mit; dabei stehen \(stats.totalScored) erzielte und \(stats.totalAgainst) erhaltene Tore zu Buche.", recent)
        let split = all.filter { atHome ? $0.$homeTeam.id == teamID : $0.$awayTeam.id == teamID }
        if !split.isEmpty {
            let s = TeamStatisticsService.aggregate(teamID: teamID, matches: split)
            add("split", "\(atHome ? "In den Heimspielen" : "Auf fremdem Platz") verbucht \(teamName) bei \(split.count) erfassten Begegnungen \(s.wins) \(s.wins == 1 ? "Sieg" : "Siege"), \(s.draws) Remis und \(s.losses) \(s.losses == 1 ? "Niederlage" : "Niederlagen") sowie ein Torverhältnis von \(s.totalScored):\(s.totalAgainst).", split)
        }
        let unbeaten = all.prefix { m in m.$homeTeam.id == teamID ? m.score.home >= m.score.away : m.score.away >= m.score.home }
        if unbeaten.count >= 2 { add("streak", "\(teamName) blieb in den letzten \(unbeaten.count) berücksichtigten Spielen ohne Niederlage.", Array(unbeaten)) }
        else {
            let lost = all.prefix { m in m.$homeTeam.id == teamID ? m.score.home < m.score.away : m.score.away < m.score.home }
            if lost.count >= 2 { add("streak", "Für \(teamName) stehen zuletzt \(lost.count) Niederlagen in Folge in der Ergebnisliste.", Array(lost)) }
        }
        if let last = all.first { add("last", resultSentence(last, home: last.$homeTeam.id == teamID ? teamName : (last.homeBlanket?.name ?? "das Heimteam"), away: last.$awayTeam.id == teamID ? teamName : (last.awayBlanket?.name ?? "das Auswärtsteam")), [last]) }
        return facts
    }

    static func scorerFacts(teamID: UUID, teamName: String, matches: [Match], label: String) -> [CommentaryFact] {
        var counts = [String: (String, Int, Set<String>)]()
        for match in matches where match.status != .cancelled {
            guard match.$homeTeam.id == teamID || match.$awayTeam.id == teamID else { continue }
            let side: MatchAssignment = match.$homeTeam.id == teamID ? .home : .away
            var seen = Set<UUID>()
            for event in match.$events.value ?? [] where event.type == .goal && event.ownGoal != true {
                if let id = event.id, !seen.insert(id).inserted { continue }
                guard TeamStatisticsService.scoringAssignment(for: event, in: match) == side else { continue }
                guard let playerID = event.$player.id else { continue }
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
                text: "Für \(teamName) ist \(row.0) in den berücksichtigten Spielen mit \(row.1) persönlich zugeordneten Toren verzeichnet; die Angabe beruht auf den erfassten Torereignissen.", sourceIDs: row.2.sorted())
        }
    }

    static func resultSentence(_ match: Match, home: String, away: String) -> String {
        let date = match.details.date.map { "Am \(dateText($0)) " } ?? ""
        if match.status == .cancelled {
            return "\(date)wurde die Begegnung \(home) gegen \(away) mit \(match.score.home):\(match.score.away) gewertet; dieses Ergebnis wird nicht als auf dem Platz erzielter Spielverlauf beschrieben."
        }
        return "\(date)endete die Begegnung zwischen \(home) und \(away) mit \(match.score.home):\(match.score.away)."
    }

    static func summary(data: CommentarySeasonData, gameday: Int, allowPartial: Bool, now: Date) throws -> CommentaryContext {
        guard gameday >= 0, let seasonID = data.season.id else { throw Abort(.badRequest, reason: "Invalid game day.") }
        let fixtures = data.matches.filter { $0.details.gameday == gameday }
        guard !fixtures.isEmpty else { throw Abort(.notFound, reason: "No fixtures exist for this season/game day.") }
        let results = ordered(fixtures.filter { resultKnown($0, before: now) })
        let partial = results.count != fixtures.count
        guard !partial || allowPartial else { throw Abort(.conflict, reason: "Game day is incomplete. Explicitly allow_partial to create a labelled partial summary.") }
        guard !results.isEmpty else { throw Abort(.conflict, reason: "No confirmed, reliably dated results are available.") }
        var facts = [CommentaryFact]()
        func add(_ key: String, _ group: String, _ text: String, _ ids: [String]) {
            facts.append(.init(id: key, group: group, text: text, sourceIDs: ids.sorted()))
        }
        let ids = results.compactMap { $0.id?.uuidString }
        add("round", "opening", "\(partial ? "Der Zwischenstand" : "Der Ergebnisüberblick") zum \(gameday). Spieltag der \(data.league.name) umfasst \(results.count) bestätigte Ergebnisse bei insgesamt \(fixtures.count) angesetzten Begegnungen in der Saison \(data.season.name).", [seasonID.uuidString] + ids)
        if partial { add("partial", "opening", "Dieser Bericht ist eine Teilzusammenfassung: Für \(fixtures.count - results.count) Begegnungen liegt zum Stichtag noch kein hier berücksichtigtes bestätigtes Ergebnis vor.", fixtures.compactMap { $0.id?.uuidString }) }
        let played = results.filter { $0.status != .cancelled }
        let goals = played.reduce(0) { $0 + $1.score.home + $1.score.away }
        add("totals", "opening", "In den \(played.count) berücksichtigten gespielten Begegnungen stehen insgesamt \(goals) Tore in der Ergebnisliste; administrativ gewertete Partien sind in dieser Torbilanz nicht enthalten.", played.compactMap { $0.id?.uuidString })
        for match in results.sorted(by: { ($0.score.home + $0.score.away) > ($1.score.home + $1.score.away) }) {
            let home = name(match.$homeTeam.id, in: data, fallback: match.homeBlanket?.name)
            let away = name(match.$awayTeam.id, in: data, fallback: match.awayBlanket?.name)
            add("result.\(match.id!)", "matches", resultSentence(match, home: home, away: away), [match.id!.uuidString])
            guard match.status != .cancelled else { continue }
            var seen = Set<UUID>()
            for event in (match.$events.value ?? []).sorted(by: { $0.minute != $1.minute ? $0.minute < $1.minute : ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }) where event.type == .goal {
                guard let eventID = event.id, seen.insert(eventID).inserted,
                      let side = TeamStatisticsService.scoringAssignment(for: event, in: match) else { continue }
                let sheet = TeamStatisticsService.assignment(for: event, in: match) == .home ? match.homeBlanket : match.awayBlanket
                guard let playerName = event.name ?? sheet?.players.first(where: { $0.id == event.$player.id })?.name else { continue }
                add("event.\(eventID)", "players", "Im Spiel \(home) gegen \(away) ist \(playerName) in Minute \(event.minute) \(event.ownGoal == true ? "mit einem Eigentor zugunsten von" : "als Torschütze für") \(side == .home ? home : away) eingetragen.", [match.id!.uuidString, eventID.uuidString])
            }
        }
        let throughRound = data.matches.filter { $0.details.gameday <= gameday && resultKnown($0, before: now) }
        let beforeRound = throughRound.filter { $0.details.gameday < gameday }
        let after = TeamStatisticsService.table(teams: data.teams, matches: throughRound)
        let before = TeamStatisticsService.table(teams: data.teams, matches: beforeRound)
        for row in after.prefix(3) {
            add("table.\(row.id)", "table", "In der aus den erfassten Ergebnissen bis einschließlich dieses Spieltags berechneten Tabelle steht \(row.name) mit \(row.points) Punkten und \(row.scored):\(row.against) Toren auf Rang \(row.ranking).", throughRound.compactMap { $0.id?.uuidString })
        }
        if let a = after.first, let b = after.dropFirst().first {
            add("table.gap", "table", "Der Abstand zwischen \(a.name) und \(b.name) beträgt in dieser Tabelle \(a.points - b.points) Punkte.", throughRound.compactMap { $0.id?.uuidString })
        }
        if !beforeRound.isEmpty, let old = before.first, let new = after.first, old.id != new.id {
            add("table.change", "table", "Im Vergleich zur auf früheren Spieltagen beruhenden Tabelle steht nun \(new.name) statt \(old.name) an erster Stelle.", throughRound.compactMap { $0.id?.uuidString })
        }
        let involved = Set(results.flatMap { [$0.$homeTeam.id, $0.$awayTeam.id] })
        for teamID in involved.sorted(by: { $0.uuidString < $1.uuidString }) {
            facts += scorerFacts(teamID: teamID, teamName: name(teamID, in: data), matches: results, label: "round.\(teamID)")
        }
        var titles = ["\(data.league.name): \(partial ? "Zwischenstand zum" : "Rückblick auf den") \(gameday). Spieltag"]
        if !partial, let top = played.max(by: { $0.score.home + $0.score.away < $1.score.home + $1.score.away }), top.score.home + top.score.away >= 6 {
            titles.append("\(data.league.name): \(top.score.home):\(top.score.away) zwischen \(name(top.$homeTeam.id, in: data)) und \(name(top.$awayTeam.id, in: data)) am \(gameday). Spieltag")
        }
        return .init(kind: .gameDaySummary, targetKey: "season:\(seasonID):gameday:\(gameday)", seasonID: seasonID,
            matchID: nil, gameday: gameday, cutoff: now, historical: false, partial: partial,
            leagueCode: data.league.code ?? "", titles: titles,
            facts: facts, requiredFactIDs: partial ? ["round", "partial"] : ["round"],
            warnings: ["Tabellen berücksichtigen nur die erfassten Ergebnisse bis einschließlich der angefragten Spieltagsnummer.", "Nicht eingetragene Ereignisse und frühere Datenbankversionen sind unbekannt."])
    }
}
