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

    /// Team + player for every event (jersey number → lineup). Returns mapped events and review notes.
    static func mapEvents(_ input: [VeoEvent], match: Match, swapped: Bool) -> (events: [VeoEvent], notes: [String]) {
        var notes: [String] = []
        let events = input.map { event -> VeoEvent in
            var e = event
            var team = event.veoTeam.flatMap { MatchAssignment(rawValue: $0.lowercased()) }
            if swapped { team = team.map { $0 == .home ? .away : .home } }
            e.team = team
            if let team, let number = event.jerseyNumber {
                let lineup = (team == .home ? match.homeBlanket : match.awayBlanket)?.players ?? []
                let hits = lineup.filter { $0.number == number }
                if hits.count == 1 {
                    e.playerId = hits[0].id
                    e.playerName = hits[0].name
                } else if ["goal", "shot", "yellow_card", "red_card"].contains(event.type) {
                    notes.append("\(event.type) bei \(Int(event.videoSecond))s: Rückennummer \(number) nicht eindeutig im Kader")
                }
            }
            return e
        }
        return (events, notes)
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
