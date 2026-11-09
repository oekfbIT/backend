import Fluent
import FluentMongoDriver
import MongoKitten
import Vapor

struct CommentarySeasonJob: Content {
    let id: String
    let gameday: Int
    let state: CommentaryJobState
    let attempts: Int
    let lastError: String?
}
struct CommentarySeasonNews: Content {
    let id: UUID
    let title: String
    let excerpt: String
    let created: Date?
    let weekly: Bool
}
struct CommentarySeasonRound: Content {
    let gameday: Int
    let job: CommentarySeasonJob?
    let articleID: String?
    let weeklyNewsID: UUID?
    let news: [CommentarySeasonNews]
}
struct CommentarySeasonOverview: Content {
    let seasonID: UUID
    let rounds: [CommentarySeasonRound]

    static func fetch(_ seasonID: UUID, on database: Database) async throws -> Self {
        guard try await Season.find(seasonID, on: database) != nil else { throw Abort(.notFound) }
        guard let mongo = database as? MongoDatabaseRepresentable else { throw Abort(.serviceUnavailable) }
        let key = try BSONEncoder().encodePrimitive(seasonID)!
        let scope: Document = ["context.seasonID": key, "context.kind": CommentaryKind.gameDaySummary.rawValue]
        // Group in MongoDB: history and full fact snapshots never cross the wire for this screen.
        var jobScope = scope; jobScope["dryRun"] = false
        let jobs: [CommentarySeasonJob] = try await mongo.raw[CommentaryJob.schema].aggregate([
            .match(jobScope), .sort(["createdAt": .descending, "_id": .descending]),
            .init(document: ["$group": ["_id": "$targetKey", "latest": ["$first": "$$ROOT"] as Document] as Document]),
            .init(document: ["$replaceRoot": ["newRoot": "$latest"] as Document]),
            .init(document: ["$project": ["_id": 0, "id": "$_id", "gameday": "$context.gameday", "state": 1, "attempts": 1, "lastError": 1] as Document])
        ]).decode(CommentarySeasonJob.self).allResults().get()
        let articles = try await mongo.raw[CommentaryArticle.schema].find(scope, as: CommentaryArticle.self).allResults().get()
        let matches = try await Match.query(on: database).filter(\.$season.$id == seasonID).all()
        let matchDays = Dictionary(matches.compactMap { m in m.id.map { ($0.uuidString.lowercased(), m.details.gameday) } }, uniquingKeysWith: { a, _ in a })
        let matchKeys = matchDays.keys.flatMap { [$0, $0.uppercased()] }
        let newsIDs = articles.compactMap(\.publishedNewsID)
        var news = [NewsItem]()
        if !matchKeys.isEmpty || !newsIDs.isEmpty {
            news = try await NewsItem.query(on: database).group(.or) { q in
                if !newsIDs.isEmpty { q.filter(\.$id ~~ newsIDs) }
                if !matchKeys.isEmpty { q.filter(\.$matchID ~~ matchKeys) }
            }.all()
        }
        let articleByDay = Dictionary(articles.map { ($0.context.gameday, $0) }, uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
        let jobByDay: [Int: CommentarySeasonJob] = Dictionary(jobs.map { ($0.gameday, $0) }, uniquingKeysWith: { a, _ in a })
        let newsDay = Dictionary(articles.compactMap { a in a.publishedNewsID.map { ($0, a.context.gameday) } }, uniquingKeysWith: { a, _ in a })
        var byDay = [Int: [CommentarySeasonNews]]()
        for item in news {
            guard let id = item.id, let day = newsDay[id] ?? item.matchID.flatMap({ matchDays[$0.lowercased()] }) else { continue }
            let plain = (item.text ?? "").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            byDay[day, default: []].append(.init(id: id, title: item.title ?? "News", excerpt: String(plain.prefix(240)), created: item.created, weekly: newsDay[id] != nil))
        }
        let days = Set(matches.map { $0.details.gameday }).union(articleByDay.keys).union(jobByDay.keys)
        return .init(seasonID: seasonID, rounds: days.sorted().map { day in
            let items = (byDay[day] ?? []).sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            return .init(gameday: day, job: jobByDay[day], articleID: articleByDay[day]?.id,
                         weeklyNewsID: items.first(where: \.weekly)?.id, news: items)
        })
    }
}

struct CommentarySeasonIndexesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let mongo = database as? MongoDatabaseRepresentable else { return }
        try await mongo.raw[CommentaryArticle.schema].createIndex(named: "commentary_season_kind", keys: ["context.seasonID": 1, "context.kind": 1]).get()
        try await mongo.raw[CommentaryJob.schema].createIndex(named: "commentary_season_latest", keys: ["context.seasonID": 1, "context.kind": 1, "dryRun": 1, "createdAt": -1]).get()
        try await mongo.raw[NewsItem.schema].createIndex(named: "news_match", keys: ["matchID": 1]).get()
    }
    func revert(on database: Database) async throws { }
}
