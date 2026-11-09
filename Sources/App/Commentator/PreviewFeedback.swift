import Fluent
import Foundation
import MongoKitten
import Vapor

enum PreviewFeedbackVote: String, Content { case like, dislike }
struct PreviewFeedbackRequest: Content {
    let visitorId: UUID
    let previewVersion: String
    let vote: PreviewFeedbackVote? // null removes the browser's vote.
}
struct PreviewFeedbackSummary: Content {
    let previewVersion: String
    let likes: Int
    let dislikes: Int
    var vote: PreviewFeedbackVote? = nil
}
struct PreviewFeedbackEdition: Content {
    let id: String
    let matchID: String
    let articleID: String
    let content: GeneratedCommentary
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case id = "_id", matchID, articleID, content, createdAt }
}
struct PreviewFeedbackEditionReport: Content {
    let previewVersion: String
    let current: Bool
    let likes: Int
    let dislikes: Int
    let content: GeneratedCommentary
}
struct PreviewFeedbackReport: Content { let versions: [PreviewFeedbackEditionReport] }

/// Anonymous editorial feedback; never changes content or triggers inference/training.
struct PreviewFeedbackService {
    static let votes = "commentary_preview_feedback"
    static let editions = "commentary_preview_feedback_versions"
    let database: Database
    var store: MongoCommentaryStore { .init(database: database) }

    static func version(articleID: String, content: GeneratedCommentary) -> String {
        // A draft edit/regeneration does not change the hash of the public snapshot.
        // An edit to published text does; versioning also distinguishes generation metadata.
        let parts = [articleID, content.title, content.text, content.provider,
            content.model, content.promptVersion, content.contextHash, String(content.generatedAt.timeIntervalSince1970)]
        return CommentaryEncoding.hash(parts.map { "\($0.utf8.count):\($0)" }.joined())
    }

    func published(_ matchID: UUID, expectedVersion: String? = nil) async throws -> (CommentaryArticle, GeneratedCommentary, String) {
        let id = CommentaryJobService.articleID(target: "match:\(matchID)")
        guard let article = try await store.article(id), article.context.kind == .matchPreview,
              let content = article.publishedPreview ?? (article.content.status == .published ? article.content : nil) else {
            throw Abort(.notFound, reason: "No published match preview.")
        }
        let version = Self.version(articleID: id, content: content)
        if let expectedVersion, expectedVersion != version {
            throw Abort(.conflict, reason: "The published preview changed. Reload it before voting.")
        }
        return (article, content, version)
    }

    func counts(version: String) async throws -> PreviewFeedbackSummary {
        let collection = try store.collection(Self.votes)
        async let likes = collection.count(["previewVersion": version, "vote": "like"]).get()
        async let dislikes = collection.count(["previewVersion": version, "vote": "dislike"]).get()
        return try await .init(previewVersion: version, likes: Int(likes), dislikes: Int(dislikes))
    }

    func summary(matchID: UUID, expectedVersion: String?) async throws -> PreviewFeedbackSummary {
        let (_, _, version) = try await published(matchID, expectedVersion: expectedVersion)
        return try await counts(version: version)
    }

    func submit(matchID: UUID, request: PreviewFeedbackRequest, now: Date = Date()) async throws -> PreviewFeedbackSummary {
        let (article, content, version) = try await published(matchID, expectedVersion: request.previewVersion)
        let edition = PreviewFeedbackEdition(id: version, matchID: matchID.uuidString, articleID: article.id, content: content, createdAt: now)
        do {
            try await store.update(Self.editions, query: ["_id": version],
                changes: ["$setOnInsert": try BSONEncoder().encode(edition)], upsert: true)
        } catch {
            guard try await store.collection(Self.editions).findOne(["_id": version]).get() != nil else { throw error }
        }
        // Store a per-edition digest, never a raw visitor ID, IP, login or browser fingerprint.
        let voter = CommentaryEncoding.hash("preview-vote:\(version):\(request.visitorId.uuidString)")
        let fields: Document = ["previewVersion": version, "matchID": matchID.uuidString,
                                "vote": request.vote?.rawValue ?? "none", "updatedAt": now]
        do {
            try await store.update(Self.votes, query: ["_id": voter],
                changes: ["$set": fields, "$setOnInsert": ["createdAt": now] as Document], upsert: true)
        } catch {
            // Concurrent first votes may race on _id; a normal update preserves one record.
            guard try await store.collection(Self.votes).findOne(["_id": voter]).get() != nil else { throw error }
            try await store.update(Self.votes, query: ["_id": voter], changes: ["$set": fields])
        }
        var result = try await counts(version: version)
        result.vote = request.vote
        return result
    }

    func report(matchID: UUID) async throws -> PreviewFeedbackReport {
        let id = CommentaryJobService.articleID(target: "match:\(matchID)")
        let article = try await store.article(id)
        let content = article?.publishedPreview ?? (article?.content.status == .published ? article?.content : nil)
        let current = content.map { Self.version(articleID: id, content: $0) }
        let editions = try await store.collection(Self.editions).find(["matchID": matchID.uuidString], as: PreviewFeedbackEdition.self)
            .sort(["createdAt": -1]).limit(50).allResults().get()
        var versions = [PreviewFeedbackEditionReport]()
        for edition in editions {
            let count = try await counts(version: edition.id)
            versions.append(.init(previewVersion: edition.id, current: edition.id == current,
                likes: count.likes, dislikes: count.dislikes, content: edition.content))
        }
        return .init(versions: versions)
    }
}

struct PreviewFeedbackIndexesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        let store = MongoCommentaryStore(database: database)
        try await store.collection(PreviewFeedbackService.votes).createIndex(named: "preview_feedback_counts", keys: ["previewVersion": 1, "vote": 1]).get()
        try await store.collection(PreviewFeedbackService.editions).createIndex(named: "preview_feedback_history", keys: ["matchID": 1, "createdAt": -1]).get()
    }
    func revert(on database: Database) async throws { /* Preserve feedback on rollback. */ }
}
