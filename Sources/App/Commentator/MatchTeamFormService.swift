import Fluent
import Vapor

struct MatchTeamFormResponse: Content {
    let home: [FormItem]
    let away: [FormItem]
    let cutoff: Date?
}

enum MatchTeamFormService {
    static func fetch(id: UUID, on db: Database, now: Date = Date()) async throws -> MatchTeamFormResponse {
        guard let match = try await Match.find(id, on: db) else { throw Abort(.notFound) }
        guard let seasonID = match.$season.id, let date = match.details.date else { return .init(home: [], away: [], cutoff: nil) }
        let cutoff = min(date, now)
        let history = try await Match.query(on: db).filter(\.$season.$id == seasonID)
            .filter(Match.FieldKeys.date, .lessThan, cutoff)
            .group(.or) {
                $0.filter(\.$homeTeam.$id ~~ [match.$homeTeam.id, match.$awayTeam.id])
                $0.filter(\.$awayTeam.$id ~~ [match.$homeTeam.id, match.$awayTeam.id])
            }
            .sort(Match.FieldKeys.date, .descending).limit(200).all()
        return forms(for: match, history: history, now: now)
    }

    static func forms(for match: Match, history: [Match], now: Date) -> MatchTeamFormResponse {
        guard let date = match.details.date else { return .init(home: [], away: [], cutoff: nil) }
        let cutoff = min(date, now)
        let earlier = history.filter {
            $0.id != match.id && $0.$season.id == match.$season.id && CommentaryContextBuilder.resultKnown($0, before: cutoff)
        }
        return .init(home: TeamStatisticsService.recentForm(teamID: match.$homeTeam.id, matches: earlier),
                     away: TeamStatisticsService.recentForm(teamID: match.$awayTeam.id, matches: earlier), cutoff: cutoff)
    }
}
