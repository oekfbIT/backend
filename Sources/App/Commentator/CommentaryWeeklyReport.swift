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
        // Protect one turning point per match before spending the budget on supporting facts.
        let arcIDs = context.facts.filter { $0.id.hasPrefix("arc.") }.map(\.id)
        let arcsByGroup = Dictionary(grouping: arcIDs) { facts[$0]!.group }
        for group in order {
            guard let options = arcsByGroup[group], let fallback = options.first else { continue }
            append(ranked.first(where: { options.contains($0) }) ?? fallback)
            if !selected.contains(where: { options.contains($0) }) { append(fallback) }
        }
        let arcs = Set(arcIDs)
        let supporting = (ranked + context.facts.map(\.id)).filter { !arcs.contains($0) }
        let candidates = order.map { group in
            var seen = Set<String>()
            return supporting.filter { id in facts[id]?.group == group && seen.insert(id).inserted }
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
            let groupIDs = selected.filter { facts[$0]?.group == group }
            // A named performance can lead a result when the timeline offers no turning point.
            let lead = groupIDs.first { arcs.contains($0) } ?? groupIDs.first { $0.hasPrefix("scorer.") }
            let ids = lead.map { [$0] } ?? []
            let orderedIDs = ids + groupIDs.filter { $0 != lead }
            for start in stride(from: 0, to: orderedIDs.count, by: 8) {
                paragraphs.append(Array(orderedIDs[start..<min(start + 8, orderedIDs.count)]))
            }
        }
        return .init(titleIndex: selection.titleIndex, language: selection.language, paragraphs: paragraphs)
    }
}

extension CommentaryContextBuilder {
    static func weeklyResultReady(_ match: Match) -> Bool {
        switch match.status {
        case .pending, .first, .halftime, .second: return false
        case .completed, .submitted, .done, .cancelled, .abbgebrochen: return true
        }
    }

    private static func matchArcs(_ match: Match, home: String, away: String) -> (texts: [String], sources: [String])? {
        guard let id = match.id else { return nil }
        var goals = [(minute: Int, side: MatchAssignment)](), sources = Set<UUID>()
        for event in match.$events.value ?? [] where event.type == .goal {
            guard let eventID = event.id, event.$match.id == id, sources.insert(eventID).inserted,
                  event.minute > 0,
                  let side = TeamStatisticsService.scoringAssignment(for: event, in: match) else { return nil }
            goals.append((event.minute, side))
        }
        guard !goals.isEmpty, goals.filter({ $0.side == .home }).count == match.score.home,
              goals.filter({ $0.side == .away }).count == match.score.away else { return nil }

        // Goals within the same minute have no recorded order. Use the score after the whole minute.
        var score = Score(home: 0, away: 0)
        let minutes = Dictionary(grouping: goals, by: \.minute)
        let checkpoints = minutes.keys.sorted().map { minute in
            let homeGoals = minutes[minute]!.filter { $0.side == .home }.count
            let awayGoals = minutes[minute]!.count - homeGoals
            score.home += homeGoals
            score.away += awayGoals
            return (minute: minute, score: score, homeGoals: homeGoals, awayGoals: awayGoals)
        }
        let sourceIDs = ([id] + Array(sources)).map(\.uuidString).sorted()
        let halfLength = 25
        let lateMinute = 2 * halfLength - 5
        // The match clock can record minute 25 on either side of halftime.
        let halftime = minutes[halfLength] == nil
            ? checkpoints.last(where: { $0.minute < halfLength })?.score ?? Score(home: 0, away: 0)
            : nil
        if score.home == score.away {
            guard let last = checkpoints.last, last.minute >= lateMinute, last.homeGoals + last.awayGoals == 1 else { return nil }
            let team = last.homeGoals == 1 ? home : away
            return (["\(team) rettete mit dem Ausgleich in Minute \(last.minute) einen Punkt."], sourceIDs)
        }

        let homeWon = score.home > score.away
        let winner = homeWon ? home : away
        func difference(_ score: Score) -> Int { homeWon ? score.home - score.away : score.away - score.home }
        func winnerGoals(_ score: Score) -> Int { homeWon ? score.home : score.away }
        func winnerScore(_ score: Score) -> String { homeWon ? score.displayText : "\(score.away):\(score.home)" }
        if let lowest = checkpoints.min(by: { difference($0.score) < difference($1.score) }), difference(lowest.score) < 0 {
            let first = checkpoints[0]
            let opened = homeWon ? first.awayGoals == 0 : first.homeGoals == 0
            let lead = opened ? "\(winner) traf zum 1:0, lag zwischenzeitlich aber \(winnerScore(lowest.score)) zurück."
                : "\(winner) musste einen \(winnerScore(lowest.score))-Rückstand aufholen."
            if let halftime, difference(halftime) < 0 {
                let secondHalfGoals = winnerGoals(score) - winnerGoals(halftime)
                let turnaround = secondHalfGoals >= 3
                    ? "Mit \(secondHalfGoals) Treffern nach der Pause drehte das Team die Partie."
                    : "Nach der Pause drehte das Team die Partie."
                let pauseLead = opened
                    ? "Trotz des 1:0 lag \(winner) zur Pause \(winnerScore(halftime)) hinten."
                    : "\(winner) ging mit einem \(winnerScore(halftime))-Rückstand in die Pause."
                return ([lead + " " + turnaround, pauseLead + " " + turnaround], sourceIDs)
            }
            var run = 0, turnaroundRun = 0, beforeRun = 0, previous = 0
            for checkpoint in checkpoints {
                let opponentGoals = homeWon ? checkpoint.awayGoals : checkpoint.homeGoals
                let current = difference(checkpoint.score)
                if opponentGoals == 0 {
                    if run == 0 { beforeRun = previous }
                    run += current - previous
                    if beforeRun < 0 && current > 0 { turnaroundRun = max(turnaroundRun, run) }
                } else {
                    // A mixed minute breaks a streak whose order cannot be verified.
                    run = 0
                }
                previous = current
            }
            let turnaround = turnaroundRun >= 3
                ? "\(turnaroundRun) Treffer in Folge brachten das Team in Führung."
                : "Am Ende drehte das Team die Partie."
            return ([lead + " " + turnaround], sourceIDs)
        }
        let lastLevel = checkpoints.lastIndex { difference($0.score) == 0 }
        let decisiveLead = checkpoints[(lastLevel ?? -1) + 1]
        if decisiveLead.minute >= lateMinute, decisiveLead.homeGoals + decisiveLead.awayGoals == 1 {
            return (["In Minute \(decisiveLead.minute) ging \(winner) in Führung und gab sie bis zum Abpfiff nicht mehr ab."], sourceIDs)
        }
        if let halftime, difference(score) - difference(halftime) >= 3 {
            let lead = difference(halftime) == 0 ? "Zur Pause stand es \(halftime.displayText)."
                : "\(winner) führte zur Pause \(winnerScore(halftime))."
            return ([lead + " Mit \(winnerGoals(score) - winnerGoals(halftime)) Treffern nach dem Seitenwechsel zog \(winner) davon."], sourceIDs)
        }
        if let halftime, difference(halftime) >= 3 {
            return (["\(winner) lag zur Pause bereits \(winnerScore(halftime)) vorne."], sourceIDs)
        }
        return nil
    }

    static func weeklySummary(data: CommentarySeasonData, gameday: Int, allowPartial: Bool, now: Date) throws -> CommentaryContext {
        guard gameday >= 0, let seasonID = data.season.id else { throw Abort(.badRequest, reason: "Invalid game day.") }
        let scoped = data.matches.filter { $0.$season.id == seasonID }
        let fixtures = scoped.filter { $0.details.gameday == gameday }
        guard !fixtures.isEmpty else { throw Abort(.notFound, reason: "No fixtures exist for this season/game day.") }
        let results = ordered(fixtures.filter(weeklyResultReady))
        let partial = results.count != fixtures.count
        guard !partial || allowPartial else { throw Abort(.conflict, reason: "Game day is incomplete. Explicitly allow_partial to create a labelled partial summary.") }
        guard !results.isEmpty else { throw Abort(.conflict, reason: "No completed matches are available.") }
        let through = scoped.filter { $0.details.gameday <= gameday && weeklyResultReady($0) && $0.status != .abbgebrochen && TeamStatisticsService.countsAsResult($0) }
        let earlier = through.filter { $0.details.gameday < gameday }
        let after = TeamStatisticsService.table(teams: data.teams, matches: through)
        let before = TeamStatisticsService.table(teams: data.teams, matches: earlier)
        let played = results.filter { $0.status != .cancelled && $0.status != .abbgebrochen }
        var facts = [CommentaryFact](), headings = [String: String](), required = ["round", "totals"]
        func add(_ id: String, _ group: String, _ text: String, _ sources: [String]) {
            facts.append(.init(id: id, group: group, text: text, sourceIDs: Array(Set(sources)).sorted()))
        }
        let sourceIDs = results.compactMap { $0.id?.uuidString }
        add("round", "opening", "Am \(gameday). Spieltag der \(data.league.name) werden \(results.count) Begegnungen der Saison \(data.season.name) zusammengefasst.", [seasonID.uuidString] + sourceIDs)
        let goals = played.reduce(0) { $0 + $1.score.home + $1.score.away }
        add("totals", "opening", "Die \(played.count) gespielten Partien brachten zusammen \(goals) Tore.\(played.count != results.count ? " Strafverifizierte und abgebrochene Begegnungen sind in dieser Torzahl nicht enthalten." : "")", sourceIDs)
        if partial {
            add("partial", "opening", "Dieser Zwischenbericht ist noch unvollständig: Für \(fixtures.count - results.count) Begegnungen steht ein bestätigtes Ergebnis aus.", fixtures.compactMap { $0.id?.uuidString })
            required.append("partial")
        }
        let sorted = results.sorted {
            let a = $0.status == .cancelled ? -1 : $0.score.home + $0.score.away
            let b = $1.status == .cancelled ? -1 : $1.score.home + $1.score.away
            return a != b ? a > b : $0.id!.uuidString < $1.id!.uuidString
        }
        let highestTotal = played.map { $0.score.home + $0.score.away }.max()
        let shareHighestTotal = played.filter { $0.score.home + $0.score.away == highestTotal }.count > 1
        for match in sorted {
            let id = match.id!, group = "match.\(id)", home = name(match.$homeTeam.id, in: data), away = name(match.$awayTeam.id, in: data)
            headings[group] = "\(home) – \(away) \(match.score.home):\(match.score.away)"
            if match.status == .cancelled || match.status == .abbgebrochen {
                headings[group] = "\(home) – \(away)"
                let note: String
                if match.status == .abbgebrochen {
                    note = "Die Begegnung zwischen \(home) und \(away) wurde während des Spiels abgebrochen."
                } else if (match.score.home == 6 && match.score.away == 0) || (match.score.home == 0 && match.score.away == 6) {
                    let forfeiting = match.score.home == 0 ? home : away
                    let winner = match.score.home == 6 ? home : away
                    note = "\(forfeiting) hat die Begegnung gegen \(winner) aufgegeben; das Spiel wurde mit 6:0 für \(winner) strafverifiziert."
                } else {
                    note = "Die Begegnung zwischen \(home) und \(away) wurde mit \(match.score.home):\(match.score.away) strafverifiziert."
                }
                add("result.\(id)", group, note, [id.uuidString])
                required.append("result.\(id)")
                continue
            }
            let total = match.score.home + match.score.away, margin = abs(match.score.home - match.score.away)
            let winner = match.score.home > match.score.away ? home : away
            let loser = match.score.home > match.score.away ? away : home
            let winningScore = "\(max(match.score.home, match.score.away)):\(min(match.score.home, match.score.away))"
            let arc = matchArcs(match, home: home, away: away)
            let result: String
            if margin == 0 {
                result = total == 0 ? "\(home) und \(away) blieben beim 0:0 torlos."
                    : "\(home) und \(away) trafen je \(match.score.home)-mal und teilten sich die Punkte."
            } else if min(match.score.home, match.score.away) == 0 && margin >= 3 {
                result = "\(winner) erzielte gegen \(loser) \(margin) Tore und blieb ohne Gegentreffer."
            } else if arc != nil {
                result = "\(winner) gewann \(winningScore)."
            } else if margin == 1 {
                result = "\(winner) setzte sich mit \(winningScore) knapp gegen \(loser) durch."
            } else if margin >= 4 {
                result = "\(winner) schlug \(loser) mit \(margin) Toren Vorsprung."
            } else {
                result = "\(winner) gewann \(winningScore) gegen \(loser)."
            }
            add("result.\(id)", group, result, [id.uuidString])
            required.append("result.\(id)")
            if let arc {
                for (index, text) in arc.texts.enumerated() {
                    add("arc.\(id).\(index)", group, text, arc.sources)
                }
            }
            if total >= 10 && margin != 0 {
                if !partial && total == highestTotal {
                    let ranking = shareHighestTotal ? "eine der torreichsten Partien" : "die torreichste Partie"
                    add("outcome.\(id)", group, "Mit \(total) Toren war es \(ranking) des Spieltags.", played.compactMap { $0.id?.uuidString })
                } else {
                    add("outcome.\(id)", group, "Insgesamt fielen \(total) Tore.", [id.uuidString])
                }
            }
            let scorer = scorerRace([match])
            let standout = Array(scorer.rows.prefix(3).filter { $0.goals >= 2 })
            if !standout.isEmpty {
                let contributions = standout.map { row in
                    "\(row.name.trimmingCharacters(in: .whitespacesAndNewlines)) traf \(scorer.complete ? "" : "mindestens ")\(row.goals)-mal"
                }
                let sentence = contributions.dropLast().joined(separator: ", ")
                let text = contributions.count > 1 ? "\(sentence) und \(contributions.last!)." : "\(contributions[0])."
                add("scorer.\(id).highlights", group, text, standout.flatMap { Array($0.sources) })
            }
            var seen = Set<UUID>()
            let cards = (match.$events.value ?? []).filter {
                guard let eventID = $0.id else { return false }
                return $0.$match.id == id && seen.insert(eventID).inserted && [.yellowCard, .redCard, .yellowRedCard].contains($0.type)
            }
            let yellow = cards.filter { $0.type == .yellowCard }.count
            if yellow >= 4 { add("yellow.\(id)", group, "Im Spielbericht stehen außerdem \(yellow) \(yellow == 1 ? "Gelbe Karte" : "Gelbe Karten").", [id.uuidString] + cards.compactMap { $0.id?.uuidString }) }
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
        let reportDate: String
        if let firstDate = reportDates.first, let lastDate = reportDates.last {
            let firstDay = dateText(firstDate, matchClock: true), lastDay = dateText(lastDate, matchClock: true)
            reportDate = firstDay == lastDay ? firstDay : "\(firstDay)–\(lastDay)"
        } else {
            reportDate = "Spieltag \(gameday)"
        }
        let reportTitle = "ÖKFB Spielbericht \(reportDate) - \(data.league.name)\(partial ? " (Zwischenstand)" : "")"
        return .init(kind: .gameDaySummary, targetKey: "season:\(seasonID):gameday:\(gameday)", seasonID: seasonID,
                     matchID: nil, gameday: gameday, cutoff: now, historical: false, partial: partial, leagueCode: data.league.code ?? "",
                     titles: [reportTitle],
                     facts: facts, requiredFactIDs: required,
                     warnings: ["Nur diese Saison und Ergebnisse bis zur Spieltagsnummer und zum Stichtag.", "Keine erfundenen Spielverläufe. Torjäger-Rangsprünge nur bei vollständigen Torereignissen. Tabellenplätze sind keine Abstiegsregeln."], sectionHeadings: headings)
    }
}
