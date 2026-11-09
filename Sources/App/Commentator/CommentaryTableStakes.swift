import Foundation

extension CommentaryContextBuilder {
    static func tableStakes(match: Match, table: [TableItem], fixtures: [Match], previous: [Match], now: Date) -> [CommentaryFact] {
        guard !previous.isEmpty, table.count >= 4 else { return [] }
        var facts = [CommentaryFact]()
        for (label, teamID) in [("home", match.$homeTeam.id), ("away", match.$awayTeam.id)] {
            guard let row = table.first(where: { $0.id == teamID }) else { continue }
            var angles = [String]()
            if let leader = table.first, row.ranking > 1, row.points + 3 >= leader.points {
                angles.append("Ein Sieg brächte \(row.name) auf \(row.points + 3) Punkte und damit punktemäßig in Reichweite der Spitze.")
            } else if let threshold = [3, 5].first(where: { table.count > $0 && row.ranking > $0 && row.points + 3 >= table[$0 - 1].points }) {
                angles.append("Mit einem Sieg und dann \(row.points + 3) Punkten wären die Top \(threshold) erreichbar.")
            }
            let pursuer = table.first { other in
                other.ranking > row.ranking && other.points + 3 >= row.points && fixtures.contains {
                    $0.details.gameday == match.details.gameday && $0.status == .pending && ($0.details.date.map { $0 >= now } ?? false)
                    && ($0.$homeTeam.id == other.id || $0.$awayTeam.id == other.id)
                }
            }
            if let pursuer {
                let consequence = pursuer.points + 3 > row.points ? "punktemäßig vorbeiziehen" : "nach Punkten gleichziehen"
                let area = row.ranking >= table.count - 3 ? " im unteren Tabellenbereich" : ""
                angles.append("Bei einer Niederlage droht dagegen Druck\(area): \(pursuer.name) könnte mit einem Sieg \(consequence).")
            }
            guard !angles.isEmpty else { continue }
            let text = "\(row.name) belegt mit \(row.points) Punkten Rang \(row.ranking). " + angles.joined(separator: " ")
                + " Andere Ergebnisse und die Tordifferenz entscheiden über den genauen Platz."
            let sourceIDs = previous.compactMap { $0.id?.uuidString } + fixtures.filter { $0.details.gameday == match.details.gameday }.compactMap { $0.id?.uuidString }
            facts.append(.init(id: "\(label).stakes", group: label, text: text, sourceIDs: Array(Set(sourceIDs)).sorted()))
        }
        return facts
    }
}
