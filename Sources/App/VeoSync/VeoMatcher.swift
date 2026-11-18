import Foundation
import Fluent
import Vapor

/// Assigns a Veo recording to an ÖKFB match (date + team names) and its events to teams and players.
enum VeoMatcher {

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_AT"))
            .replacingOccurrences(of: "ß", with: "ss")
            .lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// "Bida United vs. AS Vipers" → ("Bida United", "AS Vipers"). Nil for titles like "Spiel 15. Nov. 2026".
    static func teams(fromTitle title: String) -> (home: String, away: String)? {
        for separator in [" vs. ", " vs ", " VS ", " - ", " : "] {
            let parts = title.components(separatedBy: separator)
            if parts.count == 2 {
                let home = parts[0].trimmingCharacters(in: .whitespaces), away = parts[1].trimmingCharacters(in: .whitespaces)
                if !home.isEmpty, !away.isEmpty { return (home, away) }
            }
        }
        return nil
    }

    /// 0…1: share of words of the shorter name that appear in the longer one (1 = contained).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y || x.contains(y) || y.contains(x) { return 1 }
        let wa = Set(x.split(separator: " ")), wb = Set(y.split(separator: " "))
        let small = wa.count <= wb.count ? wa : wb, big = wa.count <= wb.count ? wb : wa
        return Double(small.filter { big.contains($0) }.count) / Double(max(small.count, 1))
    }

    struct MatchResult { let match: Match?; let swapped: Bool; let notes: [String] }

    /// Candidates: matches within ±1 day of the recording; best team-name score wins (≥ 1.2 of 2.0).
    static func findMatch(title: String, recordedAt: Date?, on db: Database) async throws -> MatchResult {
        guard let date = recordedAt else { return MatchResult(match: nil, swapped: false, notes: ["Kein Aufnahmedatum von Veo"]) }
        guard let names = teams(fromTitle: title) else {
            return MatchResult(match: nil, swapped: false, notes: ["Titel enthält keine Teamnamen: \(title)"])
        }
        let from = date.addingTimeInterval(-36 * 3600), to = date.addingTimeInterval(36 * 3600)
        let candidates = try await Match.query(on: db)
            .filter(Match.FieldKeys.date, .greaterThanOrEqual, from)
            .filter(Match.FieldKeys.date, .lessThanOrEqual, to)
            .with(\.$homeTeam).with(\.$awayTeam)
            .all()

        var best: (match: Match, score: Double, swapped: Bool)?
        for match in candidates {
            let home = [match.homeBlanket?.name, match.homeTeam.teamName].compactMap { $0 }
            let away = [match.awayBlanket?.name, match.awayTeam.teamName].compactMap { $0 }
            func score(_ list: [String], _ name: String) -> Double { list.map { similarity($0, name) }.max() ?? 0 }
            let straight = score(home, names.home) + score(away, names.away)
            let swapped = score(home, names.away) + score(away, names.home)
            let value = max(straight, swapped)
            if value > (best?.score ?? 0) { best = (match, value, swapped > straight) }
        }
        guard let best, best.score >= 1.2 else {
            return MatchResult(match: nil, swapped: false,
                               notes: ["Kein passendes Spiel gefunden (\(candidates.count) Spiele am Datum)"])
        }
        var notes: [String] = []
        if best.swapped { notes.append("Heim/Gast in Veo vertauscht – automatisch korrigiert") }
        if best.score < 1.8 { notes.append("Spielzuordnung unsicher (Score \(String(format: "%.1f", best.score)))") }
        return MatchResult(match: best.match, swapped: best.swapped, notes: notes)
    }

    /// Team + player for every event. Veo's team labels are unreliable; only the jersey numbers are trusted.
    /// 1. Pick the orientation (Veo side → home/away) that best fits the lineups (jersey numbers) and the result.
    /// 2. Per event: a jersey that exists only in the other team's lineup moves the event to that team.
    /// 3. Player = the lineup player with that jersey number.
    /// Returns the mapped events, whether the worker's sides were flipped, and review notes.
    static func mapEvents(_ input: [VeoEvent], match: Match) -> (events: [VeoEvent], flipped: Bool, notes: [String]) {
        var notes: [String] = []
        let home = Set((match.homeBlanket?.players ?? []).map(\.number))
        let away = Set((match.awayBlanket?.players ?? []).map(\.number))
        func side(_ e: VeoEvent, flipped: Bool) -> MatchAssignment? {
            guard let t = e.veoTeam.flatMap({ MatchAssignment(rawValue: $0.lowercased()) }) else { return nil }
            return flipped ? (t == .home ? .away : .home) : t
        }
        func fit(flipped: Bool) -> Int {
            var score = 0
            for e in input {
                guard let number = e.jerseyNumber, let team = side(e, flipped: flipped) else { continue }
                let own = team == .home ? home : away, other = team == .home ? away : home
                if own.contains(number) && !other.contains(number) { score += 1 }
                if other.contains(number) && !own.contains(number) { score -= 1 }
            }
            let goals = input.filter { $0.type == "goal" }
            let h = goals.filter { side($0, flipped: flipped) == .home }.count, a = goals.count - h
            if h == match.score.home && a == match.score.away && !goals.isEmpty { score += 25 }
            return score
        }
        let direct = fit(flipped: false), swapped = fit(flipped: true)
        let flipped = swapped > direct
        notes.append("ℹ︎ Teams über Kader/Ergebnis bestimmt (Passung \(flipped ? swapped : direct) vs. \(flipped ? direct : swapped))")
        if home.isEmpty || away.isEmpty { notes.append("Kader unvollständig – Teams nur über das Ergebnis bestimmt") }

        var moved = 0
        let events = input.map { event -> VeoEvent in
            var e = event
            var team = side(event, flipped: flipped)
            if let number = event.jerseyNumber, let t = team {
                let own = t == .home ? home : away, other = t == .home ? away : home
                if !own.contains(number) && other.contains(number) { team = t == .home ? .away : .home; moved += 1 }
            }
            e.team = team
            e.playerId = nil; e.playerName = nil
            if let team, let number = event.jerseyNumber {
                let lineup = (team == .home ? match.homeBlanket : match.awayBlanket)?.players ?? []
                let hits = lineup.filter { $0.number == number }
                if hits.count == 1 {
                    e.playerId = hits[0].id
                    e.playerName = hits[0].name
                } else if hits.count > 1 {
                    notes.append("\(event.type) bei \(Int(event.videoSecond))s: Rückennummer \(number) doppelt im Kader")
                }
            }
            return e
        }
        if moved > 0 { notes.append("ℹ︎ \(moved) Ereignisse über die Rückennummer dem anderen Team zugeordnet") }
        return (events, flipped, notes)
    }

    /// Links Veo goals/cards to the referee's MatchEvents in order (same type and team).
    static func linkRefereeEvents(_ input: [VeoEvent], matchID: UUID, on db: Database) async throws -> [VeoEvent] {
        var events = input
        let referee = try await MatchEvent.query(on: db).filter(\.$match.$id == matchID).all()
            .sorted { $0.minute < $1.minute }
        for (veoType, refType) in [("goal", MatchEventType.goal), ("yellow_card", .yellowCard), ("red_card", .redCard)] {
            for team in [MatchAssignment.home, .away] {
                let veo = events.indices.filter { events[$0].type == veoType && events[$0].team == team }
                    .sorted { events[$0].videoSecond < events[$1].videoSecond }
                let refs = referee.filter { $0.type == refType && $0.assign == team }
                for (i, index) in veo.enumerated() where i < refs.count {
                    events[index].refereeEventId = refs[i].id
                    // The referee sheet is official: it wins over the jersey number Veo read.
                    if let player = refs[i].$player.id { events[index].playerId = player; events[index].playerName = refs[i].name }
                }
            }
        }
        return events
    }
}
