import Foundation
import Vapor

extension CommentaryValidationService {
    static func normalizeWeekly(_ selection: CommentarySelection, context: CommentaryContext,
                                configuration: CommentaryConfiguration) -> CommentarySelection {
        let facts = Dictionary(uniqueKeysWithValues: context.facts.map { ($0.id, $0) })
        let ranked = selection.paragraphs.flatMap { $0 }
        let (minimum, maximum) = wordLimits(context: context, configuration: configuration)
        var selected = [String](), seen = Set<String>(), groups = Set<String>(), words = 0
        func append(_ id: String) {
            guard let fact = facts[id], !seen.contains(id) else { return }
            let headingWords = groups.contains(fact.group) ? 0 : (context.sectionHeadings?[fact.group]?.split(whereSeparator: \.isWhitespace).count ?? 0)
            let count = fact.text.split(whereSeparator: \.isWhitespace).count + headingWords
            guard words + count <= maximum else { return }
            seen.insert(id); selected.append(id); groups.insert(fact.group); words += count
        }
        context.requiredFactIDs.forEach(append)
        var order = [String]()
        for fact in context.facts where !order.contains(fact.group) { order.append(fact.group) }
        let candidates = order.map { group in
            var seen = Set<String>()
            return (ranked + context.facts.map(\.id)).filter { id in facts[id]?.group == group && seen.insert(id).inserted }
        }
        // Spread additional substance across fixtures instead of spending the budget on one game.
        for depth in 0..<(candidates.map(\.count).max() ?? 0) {
            for list in candidates where depth < list.count {
                let id = list[depth]
                if ranked.contains(id) || words < minimum { append(id) }
            }
        }
        var paragraphs = [[String]]()
        for group in order {
            let ids = selected.filter { facts[$0]?.group == group }
            for start in stride(from: 0, to: ids.count, by: 8) { paragraphs.append(Array(ids[start..<min(start + 8, ids.count)])) }
        }
        return .init(titleIndex: selection.titleIndex, language: selection.language, paragraphs: paragraphs)
    }
}

extension CommentaryContextBuilder {
    static func weeklySummary(data: CommentarySeasonData, gameday: Int, allowPartial: Bool, now: Date) throws -> CommentaryContext {
        guard gameday >= 0, let seasonID = data.season.id else { throw Abort(.badRequest, reason: "Invalid game day.") }
        let scoped = data.matches.filter { $0.$season.id == seasonID }
        let fixtures = scoped.filter { $0.details.gameday == gameday }
        guard !fixtures.isEmpty else { throw Abort(.notFound, reason: "No fixtures exist for this season/game day.") }
        let results = ordered(fixtures.filter { resultKnown($0, before: now) })
        let partial = results.count != fixtures.count
        guard !partial || allowPartial else { throw Abort(.conflict, reason: "Game day is incomplete. Explicitly allow_partial to create a labelled partial summary.") }
        guard !results.isEmpty else { throw Abort(.conflict, reason: "No confirmed, reliably dated results are available.") }
        let through = scoped.filter { $0.details.gameday <= gameday && resultKnown($0, before: now) }
        let earlier = through.filter { $0.details.gameday < gameday }
        let after = TeamStatisticsService.table(teams: data.teams, matches: through)
        let before = TeamStatisticsService.table(teams: data.teams, matches: earlier)
        let played = results.filter { $0.status != .cancelled }
        var facts = [CommentaryFact](), headings = [String: String](), required = ["round", "totals"]
        func add(_ id: String, _ group: String, _ text: String, _ sources: [String]) {
            facts.append(.init(id: id, group: group, text: text, sourceIDs: Array(Set(sources)).sorted()))
        }
        let sourceIDs = results.compactMap { $0.id?.uuidString }
        add("round", "opening", "Am \(gameday). Spieltag der \(data.league.name) sind \(results.count) von \(fixtures.count) Partien der Saison \(data.season.name) abgeschlossen.", [seasonID.uuidString] + sourceIDs)
        let goals = played.reduce(0) { $0 + $1.score.home + $1.score.away }
        add("totals", "opening", "Die \(played.count) gespielten Partien brachten zusammen \(goals) Tore.\(played.count != results.count ? " Wertungsergebnisse sind in dieser Torzahl nicht enthalten." : "")", sourceIDs)
        if partial {
            add("partial", "opening", "Dieser Zwischenbericht ist noch unvollständig: Für \(fixtures.count - results.count) Begegnungen steht ein bestätigtes Ergebnis aus.", fixtures.compactMap { $0.id?.uuidString })
            required.append("partial")
        }
        let sorted = results.sorted {
            let a = $0.status == .cancelled ? -1 : $0.score.home + $0.score.away
            let b = $1.status == .cancelled ? -1 : $1.score.home + $1.score.away
            return a != b ? a > b : $0.id!.uuidString < $1.id!.uuidString
        }
        for match in sorted {
            let id = match.id!, group = "match.\(id)", home = name(match.$homeTeam.id, in: data), away = name(match.$awayTeam.id, in: data)
            headings[group] = "\(home) – \(away) \(match.score.home):\(match.score.away)"
            add("result.\(id)", group, resultSentence(match, home: home, away: away), [id.uuidString]); required.append("result.\(id)")
            if match.status == .cancelled { continue }
            let total = match.score.home + match.score.away, margin = abs(match.score.home - match.score.away)
            let winner = match.score.home > match.score.away ? home : away
            if margin == 0 {
                add("outcome.\(id)", group, "Beide Teams nehmen einen Punkt mit.\(total >= 8 ? " Mit \(total) Treffern gehörte dieses Remis zu den torreichen Begegnungen der Runde." : "")", [id.uuidString])
            } else if margin == 1 {
                add("outcome.\(id)", group, "Nur ein Tor gab am Ende den Ausschlag: Die drei Punkte gingen an \(winner), während \(match.score.home > match.score.away ? away : home) ohne Zähler blieb.", [id.uuidString])
            } else if margin >= 4 {
                add("outcome.\(id)", group, "\(winner) holte die drei Punkte mit einem deutlichen Vorsprung von \(margin) Toren.\(total >= 10 ? " Insgesamt \(total) Treffer machten die Begegnung zugleich zu einer besonders torreichen Partie." : "")", [id.uuidString])
            } else {
                add("outcome.\(id)", group, "\(winner) verbuchte drei Punkte.\(total >= 8 ? " Mit insgesamt \(total) Toren hatte die Partie auch offensiv einiges zu bieten." : "")", [id.uuidString])
            }
            let scorer = scorerRace([match])
            for row in scorer.rows.prefix(3) where row.goals >= 2 {
                add("scorer.\(id).\(row.id)", group, "\(row.name.trimmingCharacters(in: .whitespacesAndNewlines)) steuerte \(scorer.complete ? "" : "mindestens ")\(row.goals) Treffer bei\(row.goals >= 3 ? " und gehörte damit zu den auffälligen Torschützen dieser Begegnung" : "").", Array(row.sources))
            }
            var seen = Set<UUID>()
            let cards = (match.$events.value ?? []).filter {
                guard let eventID = $0.id else { return false }
                return $0.$match.id == id && seen.insert(eventID).inserted && [.yellowCard, .redCard, .yellowRedCard].contains($0.type)
            }
            let yellow = cards.filter { $0.type == .yellowCard }.count
            if yellow > 0 { add("yellow.\(id)", group, "Im Spielbericht stehen außerdem \(yellow) \(yellow == 1 ? "Gelbe Karte" : "Gelbe Karten").", [id.uuidString] + cards.compactMap { $0.id?.uuidString }) }
            for event in cards where event.type != .yellowCard {
                guard let side = TeamStatisticsService.assignment(for: event, in: match) else { continue }
                let who = event.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let subject = (who?.isEmpty == false ? who! + " (" + (side == .home ? home : away) + ")" : (side == .home ? home : away))
                add("card.\(event.id!)", group, "Für \(subject) ist \(event.type == .redCard ? "eine Rote Karte" : "Gelb-Rot")\(event.minute > 0 ? " in Minute \(event.minute)" : "") eingetragen.", [id.uuidString, event.id!.uuidString])
            }
        }
        headings["players"] = "Die Torjäger des Spieltags"
        let oldRace = scorerRace(earlier), newRace = scorerRace(through)
        if oldRace.complete && newRace.complete {
            let involved = Set(scorerRace(played).rows.map(\.id))
            for row in newRace.rows where involved.contains(row.id) {
                let rank = 1 + newRace.rows.filter { $0.goals > row.goals }.count
                let old = oldRace.rows.first { $0.id == row.id }
                let oldRank = old == nil ? Int.max : 1 + oldRace.rows.filter { $0.goals > old!.goals }.count
                if rank <= 10 && rank < oldRank {
                    let origin = old == nil ? "neu" : "von Rang \(oldRank)"
                    let destination = rank == 1 ? (newRace.rows.filter { $0.goals == row.goals }.count > 1 ? "einen geteilten Spitzenplatz" : "den Spitzenplatz") : "Rang \(rank)"
                    add("race.\(row.id)", "players", "\(row.name) rückte mit jetzt \(row.goals) Saisontoren \(origin) auf \(destination) der Torjägerliste vor.", newRace.rows.flatMap { $0.sources })
                }
            }
        }
        headings["table"] = "So steht die Liga nach dem Spieltag"
        for row in after.prefix(3) {
            let old = before.first { $0.id == row.id }
            let movement = !earlier.isEmpty && old?.ranking != row.ranking ? " Vor der Runde war es noch Platz \(old?.ranking ?? row.ranking)." : ""
            add("table.\(row.id)", "table", "\(row.name) steht mit \(row.points) Punkten auf Platz \(row.ranking).\(movement)", through.compactMap { $0.id?.uuidString })
        }
        if let leader = after.first, let second = after.dropFirst().first {
            add("table.gap", "table", "\(leader.name) und \(second.name) trennen \(leader.points - second.points) Punkte.", through.compactMap { $0.id?.uuidString })
        }
        for row in after.dropFirst(3) where results.contains(where: { $0.$homeTeam.id == row.id || $0.$awayTeam.id == row.id }) {
            if !earlier.isEmpty, let old = before.first(where: { $0.id == row.id }), old.ranking != row.ranking {
                add("movement.\(row.id)", "table", "\(row.name) \(row.ranking < old.ranking ? "kletterte" : "fiel") von Platz \(old.ranking) auf \(row.ranking) und hält bei \(row.points) Punkten.", through.compactMap { $0.id?.uuidString })
            }
        }
        let reportDates = results.compactMap { $0.details.date }.sorted()
        guard let firstDate = reportDates.first, let lastDate = reportDates.last else {
            throw Abort(.unprocessableEntity, reason: "A weekly report requires a reliable game-day date.")
        }
        let firstDay = dateText(firstDate), lastDay = dateText(lastDate)
        let reportDate = firstDay == lastDay ? firstDay : "\(firstDay)–\(lastDay)"
        let reportTitle = "ÖKFB Spielbericht \(reportDate) - \(data.league.name)\(partial ? " (Zwischenstand)" : "")"
        return .init(kind: .gameDaySummary, targetKey: "season:\(seasonID):gameday:\(gameday)", seasonID: seasonID,
                     matchID: nil, gameday: gameday, cutoff: now, historical: false, partial: partial, leagueCode: data.league.code ?? "",
                     titles: [reportTitle],
                     facts: facts, requiredFactIDs: required,
                     warnings: ["Nur diese Saison und Ergebnisse bis zur Spieltagsnummer und zum Stichtag.", "Keine erfundenen Spielverläufe. Torjäger-Rangsprünge nur bei vollständigen Torereignissen. Tabellenplätze sind keine Abstiegsregeln."], sectionHeadings: headings)
    }
}
