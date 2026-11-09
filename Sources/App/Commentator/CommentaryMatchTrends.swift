import Foundation

extension CommentaryContextBuilder {
    /// Non-overlapping, equally sized windows, already filtered to the preview cutoff.
    /// Awarded scores cannot become evidence of played attacking/defensive performance.
    static func defensiveTrend(teamID: UUID, teamName: String, matches: [Match], label: String) -> CommentaryFact? {
        let played = ordered(matches.filter {
            $0.status != .cancelled && ($0.$homeTeam.id == teamID || $0.$awayTeam.id == teamID)
        })
        guard played.count >= 6 else { return nil }
        let recent = Array(played.prefix(3)), earlier = Array(played.dropFirst(3).prefix(3))
        let now = TeamStatisticsService.aggregate(teamID: teamID, matches: recent).totalAgainst
        let before = TeamStatisticsService.aggregate(teamID: teamID, matches: earlier).totalAgainst
        let text: String
        if before - now >= 3 {
            text = "Die Defensive von \(teamName) zeigt Besserung: \(now) Gegentore in den jüngsten drei Spielen statt \(before) in den drei davor.\(now >= 9 ? " Anfällig bleibt sie dennoch." : "")"
        } else if now - before >= 3 {
            text = "Defensiv ging der Trend bei \(teamName) zuletzt in die andere Richtung: \(now) Gegentore in drei Spielen gegenüber \(before) in den drei davor."
        } else if now >= 9 && before >= 9 {
            text = "Defensiv ist bei \(teamName) noch keine klare Entspannung zu sehen: \(now) Gegentore in den jüngsten drei Spielen nach \(before) in den drei davor."
        } else { return nil }
        return .init(id: "\(label).defence_trend", group: label, text: text,
                     sourceIDs: (recent + earlier).compactMap { $0.id?.uuidString }.sorted())
    }

    /// An editorial signal, not an expected-goals model, probability or score forecast.
    /// Use the newest THREE played matches so older high totals cannot hide recent tightening.
    static func goalOutlook(homeID: UUID, awayID: UUID, matches: [Match], historical: Bool = false) -> CommentaryFact? {
        let home = Array(ordered(matches.filter { $0.status != .cancelled && ($0.$homeTeam.id == homeID || $0.$awayTeam.id == homeID) }).prefix(3))
        let away = Array(ordered(matches.filter { $0.status != .cancelled && ($0.$homeTeam.id == awayID || $0.$awayTeam.id == awayID) }).prefix(3))
        guard home.count == 3, away.count == 3 else { return nil }
        let h = TeamStatisticsService.aggregate(teamID: homeID, matches: home)
        let a = TeamStatisticsService.aggregate(teamID: awayID, matches: away)
        func recurring(_ history: [Match], teamID: UUID) -> Bool {
            let scored = history.filter { ($0.$homeTeam.id == teamID ? $0.score.home : $0.score.away) > 0 }.count
            let conceded = history.filter { ($0.$homeTeam.id == teamID ? $0.score.away : $0.score.home) > 0 }.count
            return scored >= 2 && conceded >= 2
        }
        // Per team: >=2 scored, >=2.5 conceded and >=6 total match goals per game.
        guard recurring(home, teamID: homeID), recurring(away, teamID: awayID),
              h.totalScored >= 6, a.totalScored >= 6, h.totalAgainst >= 8, a.totalAgainst >= 8,
              h.totalScored + h.totalAgainst >= 18, a.totalScored + a.totalAgainst >= 18 else { return nil }
        let text = historical
            ? "Aus damaliger Sicht ließen die jeweils jüngsten drei Spiele ein offenes, torreiches Duell erwarten: Beide Teams trafen regelmäßig und ließen zugleich viel zu."
            : "Beide Teams trafen zuletzt regelmäßig und ließen zugleich viel zu: Ihre jeweils jüngsten drei Spiele lassen ein offenes, torreiches Duell erwarten."
        return .init(id: "goal_outlook", group: "closing", text: text,
                     sourceIDs: Array(Set((home + away).compactMap { $0.id?.uuidString })).sorted())
    }
}
