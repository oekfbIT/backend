import Foundation

extension CommentaryContextBuilder {
    /// Roster entries show squad involvement, not minutes or starts. Events additionally
    /// substantiate participation; neither can cancel a current fixture-covering ban.
    static func suspensionFacts(teamID: UUID, teamName: String, players: [Player], matches: [Match],
                                kickoff: Date, matchID: UUID, label: String) -> [CommentaryFact] {
        let recent = Array(ordered(matches.filter { $0.status != .cancelled && ($0.$homeTeam.id == teamID || $0.$awayTeam.id == teamID) }).prefix(5))
        let blocked = players.filter { $0.$team.id == teamID && $0.eligibility == .Gesperrt && ($0.blockdate.map { $0 > kickoff } ?? false) }
        var rows = [(player: Player, sheets: Int, actions: Int, goals: Int, sources: Set<String>)]()
        for player in blocked {
            guard let playerID = player.id else { continue }
            var sheets = 0, actions = 0, goals = 0, sources: Set<String> = [playerID.uuidString, matchID.uuidString]
            var seen = Set<UUID>()
            for match in recent {
                let side: MatchAssignment = match.$homeTeam.id == teamID ? .home : .away
                let sheet = side == .home ? match.homeBlanket : match.awayBlanket
                var listed = sheet?.players.contains { $0.id == playerID } ?? false
                var acted = false
                for event in match.$events.value ?? [] where event.$player.id == playerID {
                    let assigned: MatchAssignment?
                    if event.type == .goal && event.ownGoal == true, let credited = TeamStatisticsService.scoringAssignment(for: event, in: match) {
                        assigned = credited == .home ? .away : .home
                    } else { assigned = TeamStatisticsService.assignment(for: event, in: match) }
                    guard let id = event.id, seen.insert(id).inserted, event.$match.id == match.id,
                          assigned == side else { continue }
                    acted = true; listed = true; sources.insert(id.uuidString)
                    if event.type == .goal && event.ownGoal != true && TeamStatisticsService.scoringAssignment(for: event, in: match) == side { goals += 1 }
                }
                if listed { sheets += 1; if let id = match.id { sources.insert(id.uuidString) } }
                if acted { actions += 1 }
            }
            rows.append((player, sheets, actions, goals, sources))
        }
        rows.sort {
            if $0.goals != $1.goals { return $0.goals > $1.goals }
            if $0.sheets != $1.sheets { return $0.sheets > $1.sheets }
            return $0.player.id!.uuidString < $1.player.id!.uuidString
        }
        guard let key = rows.first else { return [] }
        let named = rows.prefix(2).map { $0.player.name }.joined(separator: " und ")
        let others = rows.count > 2 ? " sowie \(rows.count - 2) weitere Spieler" : ""
        var summary = "\(teamName) muss auf \(named)\(others) verzichten: \(rows.count == 1 ? "Die Sperre reicht" : "Die Sperren reichen") über den Anpfiff hinaus."
        if key.goals > 0 {
            summary += " \(key.player.name) steuerte in den letzten \(recent.count) Teamspielen \(key.goals) Treffer bei."
        } else if key.sheets > 0 {
            summary += " \(key.player.name) war in \(key.sheets) der letzten \(recent.count) Teamspielberichte verzeichnet."
        }
        var facts = [CommentaryFact(id: "\(label).suspended.summary", group: label, text: summary,
                                    sourceIDs: Array(Set(rows.flatMap { $0.sources })).sorted())]
        for row in rows {
            let evidence = row.actions > 0 ? "Für \(row.player.name) sind in \(row.actions) der letzten \(recent.count) Teamspiele eigene Spielaktionen erfasst."
                : row.sheets > 0 ? "\(row.player.name) stand in \(row.sheets) der letzten \(recent.count) Teamspielberichte; Einsatzminuten sind daraus nicht ableitbar." : ""
            facts.append(.init(id: "\(label).absence_detail.\(row.player.id!)", group: label,
                text: "Die Sperre von \(row.player.name) läuft bis \(dateText(row.player.blockdate!, time: true)). \(evidence)".trimmingCharacters(in: .whitespaces), sourceIDs: row.sources.sorted()))
        }
        return facts
    }

    struct ScorerRow {
        let id: UUID
        var name: String
        var goals = 0
        var teamIDs = Set<UUID>()
        var sources = Set<String>()
    }

    /// The supplied matches already share the fixture's season and chronological cutoff.
    /// Ranking claims require a complete reconciliation of event goals with both scorelines.
    static func scorerRace(_ matches: [Match]) -> (rows: [ScorerRow], complete: Bool) {
        var rows = [UUID: ScorerRow](), seen = Set<UUID>(), complete = !matches.isEmpty
        for match in matches where match.status != .cancelled {
            var homeGoals = 0, awayGoals = 0
            for event in match.$events.value ?? [] where event.type == .goal {
                guard let eventID = event.id, event.$match.id == match.id, seen.insert(eventID).inserted,
                      let credited = TeamStatisticsService.scoringAssignment(for: event, in: match) else {
                    complete = false; continue
                }
                if credited == .home { homeGoals += 1 } else { awayGoals += 1 }
                if event.ownGoal == true { continue }
                let sheet = credited == .home ? match.homeBlanket : match.awayBlanket
                guard let id = event.$player.id,
                      let name = event.name ?? sheet?.players.first(where: { $0.id == id })?.name,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    complete = false; continue
                }
                var row = rows[id] ?? ScorerRow(id: id, name: name)
                row.goals += 1
                row.teamIDs.insert(credited == .home ? match.$homeTeam.id : match.$awayTeam.id)
                row.sources.insert(eventID.uuidString)
                if let matchID = match.id { row.sources.insert(matchID.uuidString) }
                rows[id] = row
            }
            if homeGoals != match.score.home || awayGoals != match.score.away { complete = false }
        }
        return (rows.values.sorted { $0.goals != $1.goals ? $0.goals > $1.goals : $0.id.uuidString < $1.id.uuidString }, complete)
    }

    static func playerAngles(teamID: UUID, teamName: String, matches: [Match], players: [Player], label: String,
                             race: (rows: [ScorerRow], complete: Bool)? = nil, excludedPlayers: Set<UUID> = []) -> [CommentaryFact] {
        var facts = [CommentaryFact]()
        let race = race ?? scorerRace(matches)
        // A known transfer prevents presenting a former player as a current player to watch.
        func belongs(_ id: UUID) -> Bool { !excludedPlayers.contains(id) && (players.first(where: { $0.id == id }).map { $0.$team.id == teamID } ?? true) }
        let candidates = race.rows.filter { $0.teamIDs.contains(teamID) && belongs($0.id) }.prefix(2)
        if race.complete {
            for row in candidates {
                let rank = 1 + race.rows.filter { $0.goals > row.goals }.count
                let allSources = race.rows.flatMap { $0.sources }.sorted()
                let text: String?
                if rank > 10 && 1 + race.rows.filter({ $0.id != row.id && $0.goals > row.goals + 1 }).count <= 10 {
                    text = "Bei \(teamName) hat \(row.name) mit \(row.goals) Toren die Top 10 im Blick: Ein weiterer Treffer würde beim jetzigen Stand der Torjägerliste für einen geteilten Top-10-Platz reichen."
                } else if rank == 1, let next = race.rows.first(where: { $0.goals < row.goals }) {
                    text = "\(row.name) (\(teamName)) \(race.rows.filter { $0.goals == row.goals }.count > 1 ? "teilt sich mit" : "führt mit") \(row.goals) Toren \(race.rows.filter { $0.goals == row.goals }.count > 1 ? "die Spitze der Torjägerliste" : "die Torjägerliste an"); \(next.name) folgt mit \(next.goals)."
                } else if let leader = race.rows.first, (1...3).contains(leader.goals - row.goals) {
                    let gap = leader.goals - row.goals
                    text = "\(row.name) (\(teamName), \(row.goals) Tore) \(gap == 1 ? "fehlt noch ein Treffer" : "fehlen noch \(gap) Treffer") zum Gleichstand mit \(leader.name) an der Spitze der Torjägerliste (\(leader.goals))."
                } else { text = nil }
                if let text {
                    facts.append(.init(id: "\(label).milestone.\(row.id)", group: label, text: text, sourceIDs: Array(Set(allSources)).sorted()))
                    break // One meaningful scorer story per side, rather than a roster list.
                }
            }
        }

        let recent = Array(ordered(matches.filter { $0.$homeTeam.id == teamID || $0.$awayTeam.id == teamID }).prefix(5))
        var cards = [UUID: (name: String, yellow: Int, red: Int, yellowRed: Int, sources: Set<String>)]()
        var seen = Set<UUID>()
        for match in recent where match.status != .cancelled {
            let side: MatchAssignment = match.$homeTeam.id == teamID ? .home : .away
            for event in match.$events.value ?? [] where [.yellowCard, .redCard, .yellowRedCard].contains(event.type) {
                guard let eventID = event.id, seen.insert(eventID).inserted, event.$match.id == match.id,
                      TeamStatisticsService.assignment(for: event, in: match) == side,
                      let id = event.$player.id, belongs(id) else { continue }
                let sheet = side == .home ? match.homeBlanket : match.awayBlanket
                guard let name = event.name ?? sheet?.players.first(where: { $0.id == id })?.name, !name.isEmpty else { continue }
                var row = cards[id] ?? (name, 0, 0, 0, [])
                if event.type == .yellowCard { row.yellow += 1 }
                if event.type == .redCard { row.red += 1 }
                if event.type == .yellowRedCard { row.yellowRed += 1 }
                row.sources.insert(eventID.uuidString)
                if let matchID = match.id { row.sources.insert(matchID.uuidString) }
                cards[id] = row
            }
        }
        let notable = cards.filter { $0.value.yellow >= 3 || $0.value.red + $0.value.yellowRed > 0 }
            .sorted { a, b in
                let x = a.value.red * 5 + a.value.yellowRed * 4 + a.value.yellow
                let y = b.value.red * 5 + b.value.yellowRed * 4 + b.value.yellow
                return x != y ? x > y : a.key.uuidString < b.key.uuidString
            }
        if let (id, row) = notable.first {
            var parts = [String]()
            if row.yellow > 0 { parts.append("\(row.yellow) \(row.yellow == 1 ? "Gelbe Karte" : "Gelbe Karten")") }
            if row.red > 0 { parts.append("\(row.red) \(row.red == 1 ? "Rote Karte" : "Rote Karten")") }
            if row.yellowRed > 0 { parts.append("\(row.yellowRed)-mal Gelb-Rot") }
            facts.append(.init(id: "\(label).discipline.\(id)", group: label,
                text: "Auch die Disziplin liefert Gesprächsstoff: Bei \(teamName) sah \(row.name) in den letzten \(recent.count) Teamspielen \(parts.joined(separator: " und ")).",
                sourceIDs: row.sources.sorted()))
        }
        return facts
    }
}
