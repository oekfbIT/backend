import Crypto
import Foundation
import Vapor

enum CommentaryKind: String, Codable { case matchPreview = "match_preview", gameDaySummary = "gameday_summary" }
enum CommentaryJobState: String, Codable { case pending, running, completed, failed }
enum CommentaryStatus: String, Codable { case draft, published }

enum CommentaryEncoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func hash<T: Encodable>(_ value: T) throws -> String {
        hash(String(decoding: try encoder().encode(value), as: UTF8.self))
    }
    static func uuid(_ key: String) -> UUID {
        let h = Array(hash(key).prefix(32))
        return UUID(uuidString: String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32]))!
    }
    static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Only these allowlisted, already-verbalized facts reach inference. No Fluent models or private fields.
struct CommentaryFact: Content, Equatable {
    let id: String
    let group: String
    let text: String
    let sourceIDs: [String]
}

struct CommentaryContext: Content {
    let kind: CommentaryKind
    let targetKey: String
    let seasonID: UUID
    let matchID: UUID?
    let gameday: Int
    let cutoff: Date
    let historical: Bool
    let partial: Bool
    let leagueCode: String
    let titles: [String]
    let facts: [CommentaryFact]
    let requiredFactIDs: [String]
    let warnings: [String]

    var contextHash: String { get throws { try CommentaryEncoding.hash(self) } }
    var availableWords: Int { facts.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
}

/// The model is an editor: selects and arranges verified German sentences, never invents prose.
struct CommentarySelection: Codable {
    let titleIndex: Int
    let language: String
    let paragraphs: [[String]]
}

struct CommentaryInferenceResult {
    let selection: CommentarySelection
    let inputTokens: Int
    let outputTokens: Int
}

struct GeneratedCommentary: Content {
    let title: String
    let text: String
    let html: String
    let language: String
    let generatedAt: Date
    let provider: String
    let model: String
    let promptVersion: String
    let contextHash: String
    let factIDs: [String]
    let inputTokens: Int
    let outputTokens: Int
    var status: CommentaryStatus
}

struct CommentaryArticle: Content {
    static let schema = "commentary_articles"
    var id: String
    var jobID: String
    var revision: Int
    var manuallyEdited: Bool
    var context: CommentaryContext
    var content: GeneratedCommentary
    var publishedNewsID: UUID?
    var publishedContentHash: String?
    enum CodingKeys: String, CodingKey {
        case id = "_id", jobID, revision, manuallyEdited, context, content, publishedNewsID, publishedContentHash
    }
}

struct CommentaryJob: Content {
    static let schema = "commentary_jobs"
    var id: String
    var targetKey: String
    var articleID: String
    var state: CommentaryJobState
    var context: CommentaryContext
    var language: String
    var provider: String
    var model: String
    var promptVersion: String
    var dryRun: Bool
    var publish: Bool
    var overwrite: Bool
    var expectedRevision: Int
    var attempts: Int
    var createdAt: Date
    var updatedAt: Date
    var availableAt: Date
    var leaseUntil: Date?
    var owner: String?
    var lastError: String?
    var result: GeneratedCommentary?
    enum CodingKeys: String, CodingKey {
        case id = "_id", targetKey, articleID, state, context, language, provider, model, promptVersion,
             dryRun, publish, overwrite, expectedRevision, attempts, createdAt, updatedAt, availableAt,
             leaseUntil, owner, lastError, result
    }
}

struct CommentaryGenerationOptions: Content {
    var language: String? = nil
    var publish: Bool? = nil
    var overwrite: Bool? = nil
    var dryRun: Bool? = nil
    var allowPartial: Bool? = nil
    var idempotencyKey: String? = nil

    func validate() throws {
        guard language == nil || language == "de" || language == "de-AT" else {
            throw Abort(.badRequest, reason: "Only German (de/de-AT) is supported.")
        }
        if let key = idempotencyKey {
            guard (1...128).contains(key.utf8.count), key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw Abort(.badRequest, reason: "idempotency_key must contain 1–128 letters, numbers, underscores or hyphens.")
            }
        }
        guard overwrite != true || idempotencyKey != nil else {
            throw Abort(.badRequest, reason: "An explicit idempotency_key is required for regeneration/overwrite.")
        }
        guard dryRun != true || publish != true else { throw Abort(.badRequest, reason: "A dry run cannot publish.") }
    }
}

struct CommentaryConfiguration {
    var enabled = false
    var provider = "openai"
    var model = ""
    var apiKey = ""
    var baseURL = "https://api.openai.com/v1"
    var serviceKey = ""
    var allowServicePublish = false
    var allowPartialPublish = false
    var concurrency = 3
    var timeoutSeconds = 60
    var maxOutputTokens = 1800
    var maxAttempts = 3
    var batchLimit = 150
    var maxPreviewWords = 250
    var maxSummaryWords = 900
    var temperature: Double? = nil
    var pollSeconds = 5
    var leaseSeconds: Int { max(180, timeoutSeconds + 90) }

    static func load(_ env: (String) -> String? = Environment.get) -> Self {
        var c = Self()
        c.enabled = env("COMMENTATOR_ENABLED") == "true"
        c.provider = env("COMMENTATOR_AI_PROVIDER") ?? "openai"
        c.model = env("COMMENTATOR_AI_MODEL") ?? ""
        let providerKey = env("COMMENTATOR_AI_API_KEY") ?? ""
        c.apiKey = providerKey.isEmpty ? (env("OPENAI_API_KEY") ?? "") : providerKey
        c.baseURL = env("COMMENTATOR_AI_BASE_URL") ?? c.baseURL
        c.serviceKey = env("COMMENTATOR_SERVICE_KEY") ?? ""
        c.allowServicePublish = env("COMMENTATOR_ALLOW_SERVICE_PUBLISH") == "true"
        c.allowPartialPublish = env("COMMENTATOR_ALLOW_PARTIAL_PUBLISH") == "true"
        func int(_ key: String, _ value: Int, _ range: ClosedRange<Int>) -> Int {
            min(range.upperBound, max(range.lowerBound, Int(env(key) ?? "") ?? value))
        }
        c.concurrency = int("COMMENTATOR_CONCURRENCY", 3, 1...5)
        c.timeoutSeconds = int("COMMENTATOR_TIMEOUT_SECONDS", 60, 5...120)
        c.maxOutputTokens = int("COMMENTATOR_MAX_OUTPUT_TOKENS", 1800, 256...8000)
        c.maxAttempts = int("COMMENTATOR_MAX_ATTEMPTS", 3, 1...5)
        c.batchLimit = int("COMMENTATOR_BATCH_LIMIT", 150, 1...200)
        c.maxPreviewWords = int("COMMENTATOR_MAX_PREVIEW_WORDS", 250, 50...500)
        c.maxSummaryWords = int("COMMENTATOR_MAX_SUMMARY_WORDS", 900, 100...2000)
        c.pollSeconds = int("COMMENTATOR_POLL_SECONDS", 5, 1...60)
        if let t = Double(env("COMMENTATOR_TEMPERATURE") ?? ""), t.isFinite, (0...2).contains(t) { c.temperature = t }
        return c
    }

    func requireInference() throws {
        guard enabled else { throw Abort(.serviceUnavailable, reason: "Commentator generation is disabled.") }
        guard !provider.isEmpty, !model.trimmingCharacters(in: .whitespaces).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: baseURL), url.scheme == "https", url.host != nil, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil else {
            throw Abort(.serviceUnavailable, reason: "Configure COMMENTATOR_AI_PROVIDER, COMMENTATOR_AI_MODEL and OPENAI_API_KEY with an HTTPS API base URL.")
        }
    }
}
