import Fluent
import FluentMongoDriver
import Foundation
import MongoKitten
import Vapor

protocol CommentaryStore {
    func insertJob(_ job: CommentaryJob) async throws -> CommentaryJob
    func job(_ id: String) async throws -> CommentaryJob?
    func latest(targetKey: String) async throws -> CommentaryJob?
    func pending(now: Date, limit: Int) async throws -> [CommentaryJob]
    func claim(_ id: String, owner: String, now: Date, lease: Int, maxAttempts: Int) async throws -> CommentaryJob?
    func renew(_ id: String, owner: String, until: Date) async throws
    func finish(_ job: CommentaryJob, owner: String) async throws
    func article(_ id: String) async throws -> CommentaryArticle?
    func saveArticle(_ article: CommentaryArticle, expectedRevision: Int) async throws
    func publish(_ article: CommentaryArticle, overwrite: Bool, now: Date) async throws -> CommentaryArticle
    func acquireSlot(_ id: String, owner: String, now: Date, lease: Int) async throws -> Bool
    func releaseSlot(_ id: String, owner: String) async throws
}

/// Raw Mongo documents use deterministic _id values, compare-and-set revisions and expiring leases.
/// Every write checks server/write-concern errors; DB failures must not look like empty statistics.
struct MongoCommentaryStore: CommentaryStore {
    let database: Database
    func collection(_ name: String) throws -> MongoCollection {
        guard let db = database as? MongoDatabaseRepresentable else { throw Abort(.serviceUnavailable, reason: "Commentator requires MongoDB.") }
        return db.raw[name]
    }
    static func check(_ reply: UpdateReply) throws {
        guard reply.ok == 1, reply.writeConcernError == nil, (reply.writeErrors ?? []).isEmpty else { throw reply }
    }
    func update(_ name: String, query: Document, changes: Document, upsert: Bool = false) async throws {
        let c = try collection(name)
        let result = try await (upsert ? c.upsert(changes, where: query) : c.updateOne(where: query, to: changes)).get()
        try Self.check(result)
    }
    func modify(_ name: String, query: Document, changes: Document) async throws -> Document? {
        let reply = try await collection(name).findOneAndUpdate(where: query, to: changes, returnValue: .modified).execute().get()
        guard reply.ok == 1 else { throw reply }
        return reply.value
    }
    func insertJob(_ job: CommentaryJob) async throws -> CommentaryJob {
        do { try await update(CommentaryJob.schema, query: ["_id": job.id], changes: ["$setOnInsert": try BSONEncoder().encode(job)], upsert: true) }
        catch { guard let old = try? await self.job(job.id) else { throw error }; return old }
        guard let saved = try await self.job(job.id) else { throw Abort(.internalServerError, reason: "Generation job was not persisted.") }
        return saved
    }
    func job(_ id: String) async throws -> CommentaryJob? {
        try await collection(CommentaryJob.schema).findOne(["_id": id], as: CommentaryJob.self).get()
    }
    func latest(targetKey: String) async throws -> CommentaryJob? {
        try await collection(CommentaryJob.schema).find(["targetKey": targetKey], as: CommentaryJob.self)
            .sort(["createdAt": -1, "_id": -1]).limit(1).allResults().get().first
    }
    static func eligible(now: Date) -> Document {
        ["$or": [
            ["state": "pending", "availableAt": ["$lte": now] as Document] as Document,
            ["state": "running", "leaseUntil": ["$lte": now] as Document] as Document
        ]]
    }
    func pending(now: Date, limit: Int) async throws -> [CommentaryJob] {
        try await collection(CommentaryJob.schema).find(Self.eligible(now: now), as: CommentaryJob.self)
            .sort(["availableAt": 1, "createdAt": 1]).limit(limit).allResults().get()
    }
    func claim(_ id: String, owner: String, now: Date, lease: Int, maxAttempts: Int) async throws -> CommentaryJob? {
        var query = Self.eligible(now: now)
        query["_id"] = id
        // An expired final attempt still needs claiming to mark it failed rather than remain running forever.
        guard let result = try await modify(CommentaryJob.schema, query: query,
            changes: ["$set": ["state": "running", "owner": owner, "updatedAt": now,
                "leaseUntil": now.addingTimeInterval(Double(lease))] as Document, "$inc": ["attempts": 1]]) else { return nil }
        return try BSONDecoder().decode(CommentaryJob.self, from: result)
    }
    func renew(_ id: String, owner: String, until: Date) async throws {
        guard try await modify(CommentaryJob.schema, query: ["_id": id, "owner": owner, "state": "running"],
            changes: ["$set": ["leaseUntil": until] as Document]) != nil else {
            throw Abort(.conflict, reason: "Generation lease was lost.")
        }
    }
    func finish(_ job: CommentaryJob, owner: String) async throws {
        var document = try BSONEncoder().encode(job)
        document["_id"] = nil
        if job.lastError == nil { document["lastError"] = nil }
        var changes: Document = ["$set": document]
        if job.lastError == nil { changes["$unset"] = ["lastError": ""] as Document }
        guard try await modify(CommentaryJob.schema, query: ["_id": job.id, "owner": owner, "state": "running"],
            changes: changes) != nil else { throw Abort(.conflict, reason: "Generation lease was lost.") }
    }
    func article(_ id: String) async throws -> CommentaryArticle? {
        try await collection(CommentaryArticle.schema).findOne(["_id": id], as: CommentaryArticle.self).get()
    }
    func deletePreview(_ id: String, expectedRevision: Int) async throws {
        guard let article = try await article(id) else { throw Abort(.notFound) }
        guard article.context.kind == .matchPreview else { throw Abort(.badRequest, reason: "Only match previews can be deleted here.") }
        guard article.revision == expectedRevision else { throw Abort(.conflict, reason: "The preview changed. Refresh before deleting.") }
        guard try await collection(CommentaryJob.schema).findOne([
            "articleID": id, "state": ["$in": ["pending", "running"]] as Document
        ]).get() == nil else { throw Abort(.conflict, reason: "Wait for preview generation to finish before deleting.") }
        // Remove the entire document, including the separate public snapshot. Job history is retained.
        let reply = try await collection(CommentaryArticle.schema).deleteOne(where: ["_id": id, "revision": expectedRevision]).get()
        guard reply.ok == 1, reply.writeConcernError == nil, (reply.writeErrors ?? []).isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Preview deletion could not be confirmed.")
        }
        guard reply.deletes == 1 else { throw Abort(.conflict, reason: "The preview changed. Refresh before deleting.") }
    }
    func saveArticle(_ article: CommentaryArticle, expectedRevision: Int) async throws {
        if expectedRevision == 0 {
            do { try await update(CommentaryArticle.schema, query: ["_id": article.id], changes: ["$setOnInsert": try BSONEncoder().encode(article)], upsert: true) }
            catch {
                guard let old = try? await self.article(article.id), old.jobID == article.jobID else { throw error }
            }
            guard let old = try await self.article(article.id), old.jobID == article.jobID else {
                throw Abort(.conflict, reason: "An article already exists; explicit overwrite is required.")
            }
        } else {
            var document = try BSONEncoder().encode(article)
            document["_id"] = nil
            guard try await modify(CommentaryArticle.schema, query: ["_id": article.id, "revision": expectedRevision], changes: ["$set": document]) != nil else {
                throw Abort(.conflict, reason: "Article changed during generation; newer edits were preserved.")
            }
        }
    }

    func acquireSlot(_ id: String, owner: String, now: Date, lease: Int) async throws -> Bool {
        let c = "commentary_leases"
        do {
            try await update(c, query: ["_id": id], changes: ["$setOnInsert": ["_id": id, "owner": "", "until": Date.distantPast] as Document], upsert: true)
        } catch { guard try await collection(c).findOne(["_id": id]).get() != nil else { throw error } }
        return try await modify(c, query: ["_id": id, "$or": [["until": ["$lte": now] as Document] as Document, ["owner": owner] as Document]],
            changes: ["$set": ["owner": owner, "until": now.addingTimeInterval(Double(lease))] as Document]) != nil
    }
    func releaseSlot(_ id: String, owner: String) async throws {
        try await update("commentary_leases", query: ["_id": id, "owner": owner], changes: ["$set": ["owner": "", "until": Date.distantPast] as Document])
    }

    static func newsHash(title: String, text: String, tag: String) throws -> String {
        try CommentaryEncoding.hash([title, text, tag])
    }
    func publish(_ article: CommentaryArticle, overwrite: Bool, now: Date) async throws -> CommentaryArticle {
        guard article.context.kind == .gameDaySummary else { throw Abort(.badRequest, reason: "Only a game-day summary can publish to news.") }
        let lockID = "publish:\(article.id)", owner = UUID().uuidString
        guard try await acquireSlot(lockID, owner: owner, now: now, lease: 60) else {
            throw Abort(.conflict, reason: "This article is already being published.")
        }
        do {
            guard let current = try await self.article(article.id), current.revision == article.revision else {
                throw Abort(.conflict, reason: "The article changed before publication.")
            }
            let newsID = CommentaryEncoding.uuid("news:\(article.id)")
            let key = try BSONEncoder().encodePrimitive(newsID)!
            let tag = article.context.leagueCode
            guard !tag.isEmpty else { throw Abort(.conflict, reason: "A league news tag is required.") }
            let desiredHash = try Self.newsHash(title: article.content.title, text: article.content.html, tag: tag)
            let news = try collection(NewsItem.schema)
            if let existing = try await news.findOne(["_id": key]).get() {
                let oldTitle = existing["title"] as? String ?? "", oldText = existing["text"] as? String ?? "", oldTag = existing["tag"] as? String ?? ""
                let oldHash = try Self.newsHash(title: oldTitle, text: oldText, tag: oldTag)
                if oldHash != desiredHash {
                    guard overwrite || oldHash == article.publishedContentHash else {
                        throw Abort(.conflict, reason: "Published news was manually changed; explicit overwrite is required.")
                    }
                    guard try await modify(NewsItem.schema, query: ["_id": key, "title": oldTitle, "text": oldText, "tag": oldTag],
                        changes: ["$set": ["title": article.content.title, "text": article.content.html, "tag": tag] as Document]) != nil else {
                        throw Abort(.conflict, reason: "News changed during publication; newer edits were preserved.")
                    }
                }
            } else {
                // Deterministic _id + setOnInsert makes a crash/retry unable to create a second news story.
                try await update(NewsItem.schema, query: ["_id": key], changes: ["$setOnInsert": [
                    "_id": key, "title": article.content.title, "text": article.content.html, "tag": tag, "created": now,
                    "image": NewsItem.defaultImageURL
                ] as Document], upsert: true)
            }
            var saved = article
            saved.revision += 1
            saved.content.status = .published
            saved.publishedNewsID = newsID
            saved.publishedContentHash = desiredHash
            try await saveArticle(saved, expectedRevision: article.revision)
            try await releaseSlot(lockID, owner: owner)
            return saved
        } catch {
            try? await releaseSlot(lockID, owner: owner)
            throw error
        }
    }
}

struct CommentaryIndexesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let db = database as? MongoDatabaseRepresentable else { return }
        try await db.raw[CommentaryJob.schema].createIndex(named: "commentary_pending", keys: ["state": 1, "availableAt": 1, "leaseUntil": 1]).get()
        try await db.raw[CommentaryJob.schema].createIndex(named: "commentary_target_created", keys: ["targetKey": 1, "createdAt": -1]).get()
        try await db.raw[Match.schema].createIndex(named: "commentary_season_gameday", keys: ["season": 1, "details.gameday": 1]).get()
    }
    func revert(on database: Database) async throws { /* additive and forward-only */ }
}
