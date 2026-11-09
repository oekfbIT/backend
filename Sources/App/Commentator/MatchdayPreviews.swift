import Fluent
import MongoKitten
import Vapor

enum MatchdayPreviewState: String, Content { case existing, missing, pending, running, failed, unavailable }
struct MatchdayPreviewItem: Content {
    let matchId: UUID
    let state: MatchdayPreviewState
    let jobId: String?
    let lastError: String?
}
struct MatchdayPreviewOverview: Content {
    let seasonId: UUID
    let gameday: Int
    let items: [MatchdayPreviewItem]
    var queued = 0
    var errors: [UUID] = []
    var total: Int { items.count }
    var existing: Int { items.filter { $0.state == .existing }.count }
    var active: Int { items.filter { $0.state == .pending || $0.state == .running }.count }
    var missing: Int { items.filter { $0.state == .missing || $0.state == .failed }.count }
    var unavailable: Int { items.filter { $0.state == .unavailable }.count }
    // Computed totals are deliberately encoded for the lightweight admin progress UI.
    enum CodingKeys: String, CodingKey { case seasonId, gameday, items, queued, errors, total, existing, active, missing, unavailable }
    init(seasonId: UUID, gameday: Int, items: [MatchdayPreviewItem]) {
        self.seasonId = seasonId; self.gameday = gameday; self.items = items
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonId = try c.decode(UUID.self, forKey: .seasonId); gameday = try c.decode(Int.self, forKey: .gameday)
        items = try c.decode([MatchdayPreviewItem].self, forKey: .items)
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        errors = try c.decodeIfPresent([UUID].self, forKey: .errors) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seasonId, forKey: .seasonId); try c.encode(gameday, forKey: .gameday)
        try c.encode(items, forKey: .items); try c.encode(queued, forKey: .queued); try c.encode(errors, forKey: .errors)
        try c.encode(total, forKey: .total); try c.encode(existing, forKey: .existing)
        try c.encode(active, forKey: .active); try c.encode(missing, forKey: .missing); try c.encode(unavailable, forKey: .unavailable)
    }
}
private struct PreviewArticleKey: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "_id" }
}
private struct PreviewJobKey: Decodable { let id: String; let targetKey: String; let state: CommentaryJobState; let lastError: String? }

struct MatchdayPreviewService {
    let database: Database
    let runtime: CommentaryRuntime
    var store: MongoCommentaryStore { .init(database: database) }

    func overview(seasonID: UUID, gameday: Int) async throws -> MatchdayPreviewOverview {
        guard gameday >= 0 else { throw Abort(.badRequest, reason: "Invalid game day.") }
        guard try await Season.find(seasonID, on: database) != nil else { throw Abort(.notFound) }
        let matches = try await Match.query(on: database).filter(\.$season.$id == seasonID)
            .filter(Match.FieldKeys.gameday, .equal, gameday).all()
        guard matches.count <= runtime.configuration.batchLimit else {
            throw Abort(.badRequest, reason: "This game day exceeds the configured preview batch limit.")
        }
        let ids = matches.compactMap(\.id).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return .init(seasonId: seasonID, gameday: gameday, items: []) }
        let articleIDs = ids.map { CommentaryJobService.articleID(target: "match:\($0)") }
        let keys = ids.map { "match:\($0):de" }
        let articles = try await store.collection(CommentaryArticle.schema).aggregate([
            .match(["_id": ["$in": articleIDs] as Document]), .init(document: ["$project": ["_id": 1] as Document])
        ]).decode(PreviewArticleKey.self).allResults().get()
        func jobs(activeOnly: Bool) async throws -> [PreviewJobKey] {
            var query: Document = ["targetKey": ["$in": keys] as Document, "dryRun": false, "context.kind": CommentaryKind.matchPreview.rawValue]
            if activeOnly { query["state"] = ["$in": ["pending", "running"]] as Document }
            return try await store.collection(CommentaryJob.schema).aggregate([
                .match(query), .sort(["createdAt": .descending, "_id": .descending]),
                .init(document: ["$group": ["_id": "$targetKey", "latest": ["$first": "$$ROOT"] as Document] as Document]),
                .init(document: ["$replaceRoot": ["newRoot": "$latest"] as Document]),
                .init(document: ["$project": ["_id": 0, "id": "$_id", "targetKey": 1, "state": 1, "lastError": 1] as Document])
            ]).decode(PreviewJobKey.self).allResults().get()
        }
        async let latestJobs = jobs(activeOnly: false)
        async let activeJobs = jobs(activeOnly: true)
        let latest = try await Dictionary(uniqueKeysWithValues: latestJobs.map { ($0.targetKey, $0) })
        let active = try await Dictionary(uniqueKeysWithValues: activeJobs.map { ($0.targetKey, $0) })
        let attached = Set(articles.map(\.id))
        return .init(seasonId: seasonID, gameday: gameday, items: ids.map { id in
            let key = "match:\(id):de", job = active[key] ?? latest[key]
            let state: MatchdayPreviewState
            if attached.contains(CommentaryJobService.articleID(target: "match:\(id)")) { state = .existing }
            else if let job = active[key] { state = job.state == .pending ? .pending : .running }
            else if matches.first(where: { $0.id == id })?.details.date == nil { state = .unavailable }
            else { state = job?.state == .failed ? .failed : .missing }
            return .init(matchId: id, state: state, jobId: job?.id, lastError: job?.lastError)
        })
    }

    func generateMissing(seasonID: UUID, gameday: Int) async throws -> MatchdayPreviewOverview {
        let lock = "missing-previews:\(seasonID):\(gameday)", owner = UUID().uuidString
        guard try await store.acquireSlot(lock, owner: owner, now: Date(), lease: 180) else {
            throw Abort(.conflict, reason: "Missing previews for this game day are already being queued.")
        }
        do {
            let before = try await overview(seasonID: seasonID, gameday: gameday)
            let eligible = before.items.filter { $0.state == .missing || $0.state == .failed }
            if eligible.isEmpty { try await store.releaseSlot(lock, owner: owner); return before }
            try runtime.configuration.requireInference()
            let contexts = await runtime.contexts.matchPreviews(eligible.map(\.matchId), now: Date())
            var queued = 0, errors = [UUID]()
            for (id, result) in contexts {
                do {
                    let context = try result.get()
                    guard context.kind == .matchPreview, context.matchID == id, context.seasonID == seasonID, context.gameday == gameday else {
                        throw Abort(.conflict, reason: "Mismatched preview context.")
                    }
                    let previous = eligible.first { $0.matchId == id }?.jobId
                    // First runs share ordinary generation's initial job ID. Explicit retries
                    // of failed/deleted previews derive a stable new key from the previous job.
                    let key = previous.map { "fill-\($0)" } ?? "initial"
                    _ = try await runtime.jobs.enqueue(context: context, options: .init(publish: true, overwrite: false, idempotencyKey: key))
                    queued += 1
                } catch {
                    // Another caller may have attached a preview during context preparation.
                    if try await runtime.store.article(CommentaryJobService.articleID(target: "match:\(id)")) == nil { errors.append(id) }
                }
            }
            var after = try await overview(seasonID: seasonID, gameday: gameday)
            after.queued = queued; after.errors = errors
            try await store.releaseSlot(lock, owner: owner)
            return after
        } catch {
            try? await store.releaseSlot(lock, owner: owner)
            throw error
        }
    }
}
