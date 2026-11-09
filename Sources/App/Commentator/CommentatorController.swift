import Crypto
import Fluent
import Vapor

struct CommentaryIdentity: Authenticatable { let mayPublish: Bool }

struct CommentaryAccessMiddleware: AsyncMiddleware {
    let configuration: CommentaryConfiguration
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if let supplied = request.headers.first(name: "X-Commentator-Key") {
            let expected = configuration.serviceKey
            guard expected.utf8.count >= 32, supplied.utf8.count <= 512 else { throw Abort(.unauthorized) }
            let a = Array(SHA256.hash(data: Data(supplied.utf8))), b = Array(SHA256.hash(data: Data(expected.utf8)))
            guard zip(a, b).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { throw Abort(.unauthorized) }
            request.auth.login(CommentaryIdentity(mayPublish: configuration.allowServicePublish))
        } else {
            let user = try request.auth.require(User.self)
            guard user.hasPermission(.contentManage) else { throw Abort(.forbidden, reason: "content.manage is required.") }
            request.auth.login(CommentaryIdentity(mayPublish: true))
        }
        return try await next.respond(to: request)
    }
}

struct CommentaryStatusResponse: Content {
    let job: CommentaryJob?
    let article: CommentaryArticle?
}
struct CommentaryBatchRequest: Content { let matchIds: [UUID]; var options: CommentaryGenerationOptions? = nil }
struct CommentaryBatchItem: Content { let matchId: UUID; let job: CommentaryJob?; let error: String? }
struct CommentaryBatchResponse: Content { let items: [CommentaryBatchItem] }
struct CommentaryGameDayRequest: Content {
    let seasonId: UUID
    let gameday: Int
    var language: String? = nil
    var publish: Bool? = nil
    var overwrite: Bool? = nil
    var dryRun: Bool? = nil
    var allowPartial: Bool? = nil
    var idempotencyKey: String? = nil
    var options: CommentaryGenerationOptions {
        .init(language: language, publish: publish, overwrite: overwrite, dryRun: dryRun, allowPartial: allowPartial, idempotencyKey: idempotencyKey)
    }
}
struct CommentaryPublishRequest: Content { var overwrite: Bool? = nil }
struct CommentaryEditRequest: Content {
    let expectedRevision: Int
    let title: String
    let text: String
    var publish: Bool? = nil
}

struct MatchPreviewGenerationService {
    let runtime: CommentaryRuntime
    func generateMatchPreview(_ matchId: UUID, options: CommentaryGenerationOptions, now: Date = Date()) async throws -> CommentaryJob {
        try options.validate()
        try runtime.configuration.requireInference()
        let context = try await runtime.contexts.matchPreview(matchId, now: now)
        return try await runtime.jobs.enqueue(context: context, options: options, now: now)
    }
}
struct GameDayNewsGenerationService {
    let runtime: CommentaryRuntime
    func generateGameDaySummary(_ seasonId: UUID, gameday: Int, options: CommentaryGenerationOptions, now: Date = Date()) async throws -> CommentaryJob {
        try options.validate()
        try runtime.configuration.requireInference()
        let context = try await runtime.contexts.gameDaySummary(seasonId, gameday: gameday, allowPartial: options.allowPartial == true, now: now)
        return try await runtime.jobs.enqueue(context: context, options: options, now: now)
    }
}

struct CommentatorController: RouteCollection {
    func runtime(_ req: Request) throws -> CommentaryRuntime {
        guard let runtime = req.application.commentary else { throw Abort(.serviceUnavailable, reason: "Commentator is not configured.") }
        return runtime
    }
    func mayPublish(_ req: Request, requested: Bool) throws {
        guard !requested || req.auth.get(CommentaryIdentity.self)?.mayPublish == true else {
            throw Abort(.forbidden, reason: "This service credential is not authorized to publish.")
        }
    }
    func options(_ req: Request) throws -> CommentaryGenerationOptions {
        var options = (req.body.data?.readableBytes ?? 0) > 0 ? try req.content.decode(CommentaryGenerationOptions.self) : .init()
        if let header = req.headers.first(name: "Idempotency-Key") { options.idempotencyKey = header }
        try options.validate()
        try mayPublish(req, requested: options.shouldPublish)
        return options
    }

    func boot(routes: RoutesBuilder) throws {
        let settings = (routes as? Application)?.commentary?.configuration ?? CommentaryConfiguration.load()
        let root = routes.grouped("commenter", "v1").grouped(Token.authenticator(), CommentaryAccessMiddleware(configuration: settings), ProtectedResponseMiddleware())
        root.on(.POST, "generate", "match", ":matchId", body: .collect(maxSize: "32kb")) { req async throws -> Response in
            let id = try req.parameters.require("matchId", as: UUID.self)
            let job = try await MatchPreviewGenerationService(runtime: self.runtime(req)).generateMatchPreview(id, options: self.options(req))
            return try await job.encodeResponse(status: .accepted, for: req)
        }
        root.on(.POST, "generate", "matches", "batch", body: .collect(maxSize: "64kb")) { req async throws -> Response in
            let runtime = try self.runtime(req)
            let body = try req.content.decode(CommentaryBatchRequest.self)
            var options = body.options ?? .init()
            if let header = req.headers.first(name: "Idempotency-Key") { options.idempotencyKey = header }
            try options.validate(); try self.mayPublish(req, requested: options.shouldPublish)
            try runtime.configuration.requireInference()
            guard !body.matchIds.isEmpty, body.matchIds.count <= runtime.configuration.batchLimit else {
                throw Abort(.badRequest, reason: "Provide 1–\(runtime.configuration.batchLimit) match IDs.")
            }
            var seen = Set<UUID>()
            let ids = body.matchIds.filter { seen.insert($0).inserted }
            let contexts = await runtime.contexts.matchPreviews(ids, now: Date())
            var items = [CommentaryBatchItem]()
            for (id, context) in contexts {
                do {
                    let job = try await runtime.jobs.enqueue(context: context.get(), options: options)
                    items.append(.init(matchId: id, job: job, error: nil))
                } catch {
                    items.append(.init(matchId: id, job: nil, error: (error as? AbortError)?.reason ?? "context_or_storage_failure"))
                }
            }
            return try await CommentaryBatchResponse(items: items).encodeResponse(status: .accepted, for: req)
        }
        root.get("generate", "match", ":matchId", "status") { req async throws -> CommentaryStatusResponse in
            let id = try req.parameters.require("matchId", as: UUID.self)
            return try await self.status(req, target: "match:\(id)")
        }
        root.on(.POST, "generate", "gameday", body: .collect(maxSize: "32kb")) { req async throws -> Response in
            let body = try req.content.decode(CommentaryGameDayRequest.self)
            var options = body.options
            if let header = req.headers.first(name: "Idempotency-Key") { options.idempotencyKey = header }
            try options.validate(); try self.mayPublish(req, requested: options.shouldPublish)
            let job = try await GameDayNewsGenerationService(runtime: self.runtime(req)).generateGameDaySummary(body.seasonId, gameday: body.gameday, options: options)
            return try await job.encodeResponse(status: .accepted, for: req)
        }
        root.get("generate", "gameday", ":seasonId", ":number", "status") { req async throws -> CommentaryStatusResponse in
            let season = try req.parameters.require("seasonId", as: UUID.self), day = try req.parameters.require("number", as: Int.self)
            return try await self.status(req, target: "season:\(season):gameday:\(day)")
        }
        root.on(.POST, "generate", "gameday", ":seasonId", ":number", "publish", body: .collect(maxSize: "8kb")) { req async throws -> CommentaryArticle in
            try self.mayPublish(req, requested: true)
            let season = try req.parameters.require("seasonId", as: UUID.self), day = try req.parameters.require("number", as: Int.self)
            return try await self.publish(req, target: "season:\(season):gameday:\(day)")
        }
        root.on(.POST, "generate", "match", ":matchId", "publish", body: .collect(maxSize: "8kb")) { req async throws -> CommentaryArticle in
            try self.mayPublish(req, requested: true)
            let id = try req.parameters.require("matchId", as: UUID.self)
            return try await self.publish(req, target: "match:\(id)")
        }
        root.get("jobs", ":jobId") { req async throws -> CommentaryJob in
            guard let job = try await self.runtime(req).store.job(req.parameters.require("jobId")) else { throw Abort(.notFound) }
            return job
        }
        root.get("articles", ":articleId") { req async throws -> CommentaryArticle in
            guard let article = try await self.runtime(req).store.article(req.parameters.require("articleId")) else { throw Abort(.notFound) }
            return article
        }
        root.on(.PATCH, "articles", ":articleId", body: .collect(maxSize: "64kb")) { req async throws -> CommentaryArticle in
            try self.mayPublish(req, requested: true) // editing is an editorial capability, not ordinary automation
            let runtime = try self.runtime(req), id = try req.parameters.require("articleId")
            let edit = try req.content.decode(CommentaryEditRequest.self)
            guard var article = try await runtime.store.article(id) else { throw Abort(.notFound) }
            guard article.revision == edit.expectedRevision, !edit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !edit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...200).contains(edit.title.count), (1...30_000).contains(edit.text.utf8.count) else {
                throw Abort(.conflict, reason: "Invalid content or stale article revision.")
            }
            let publish = edit.publish ?? (article.content.status == .published)
            guard !publish || !article.context.partial || runtime.configuration.allowPartialPublish else {
                throw Abort(.conflict, reason: "Publication of partial game days is disabled.")
            }
            let old = article.content
            article.content = .init(title: edit.title, text: edit.text,
                html: edit.text.components(separatedBy: "\n\n").map { "<p>\(CommentaryEncoding.html($0))</p>" }.joined(separator: "\n"),
                language: old.language, generatedAt: old.generatedAt, provider: old.provider, model: old.model,
                promptVersion: old.promptVersion, contextHash: old.contextHash, factIDs: [], inputTokens: old.inputTokens, outputTokens: old.outputTokens, status: .draft)
            article.manuallyEdited = true; article.revision += 1
            if publish && article.context.kind == .matchPreview {
                article.content.status = .published
                article.publishedPreview = article.content
            }
            try await runtime.store.saveArticle(article, expectedRevision: edit.expectedRevision)
            if publish && article.context.kind == .gameDaySummary {
                return try await runtime.jobs.publish(article: article, overwrite: false)
            }
            return article
        }
        root.get("context", "match", ":matchId") { req async throws -> CommentaryContext in
            try await self.runtime(req).contexts.matchPreview(req.parameters.require("matchId", as: UUID.self), now: Date())
        }
        root.get("context", "gameday", ":seasonId", ":number") { req async throws -> CommentaryContext in
            try await self.runtime(req).contexts.gameDaySummary(req.parameters.require("seasonId", as: UUID.self),
                gameday: req.parameters.require("number", as: Int.self), allowPartial: req.query[Bool.self, at: "allowPartial"] == true, now: Date())
        }
        root.get("generate", "match", ":matchId", "feedback") { req async throws -> PreviewFeedbackReport in
            let id = try req.parameters.require("matchId", as: UUID.self)
            return try await PreviewFeedbackService(database: req.db).report(matchID: id)
        }
        // Existing match-detail responses remain unchanged. Only explicitly published previews are public here.
        routes.get("webClient", "match", ":matchId", "preview") { req async throws -> GeneratedCommentary in
            let id = try req.parameters.require("matchId", as: UUID.self)
            guard let article = try await self.runtime(req).store.article(CommentaryJobService.articleID(target: "match:\(id)")),
                  let published = article.publishedPreview ?? (article.content.status == .published ? article.content : nil) else { throw Abort(.notFound) }
            var response = published
            response.feedbackVersion = PreviewFeedbackService.version(articleID: article.id, content: published)
            return response
        }
        routes.get("webClient", "match", ":matchId", "preview", "feedback") { req async throws -> PreviewFeedbackSummary in
            let id = try req.parameters.require("matchId", as: UUID.self)
            return try await PreviewFeedbackService(database: req.db).summary(matchID: id,
                expectedVersion: req.query[String.self, at: "preview_version"])
        }
        routes.on(.POST, "webClient", "match", ":matchId", "preview", "feedback", body: .collect(maxSize: "2kb")) { req async throws -> PreviewFeedbackSummary in
            let id = try req.parameters.require("matchId", as: UUID.self)
            return try await PreviewFeedbackService(database: req.db).submit(matchID: id, request: req.content.decode(PreviewFeedbackRequest.self))
        }
        routes.get("webClient", "match", ":matchId", "form") { req async throws -> MatchTeamFormResponse in
            try await MatchTeamFormService.fetch(id: req.parameters.require("matchId", as: UUID.self), on: req.db)
        }
    }

    func status(_ req: Request, target: String) async throws -> CommentaryStatusResponse {
        let runtime = try self.runtime(req)
        let job = try await runtime.store.latest(targetKey: target + ":de")
        let article = try await runtime.store.article(CommentaryJobService.articleID(target: target))
        guard job != nil || article != nil else { throw Abort(.notFound) }
        return .init(job: job, article: article)
    }
    func publish(_ req: Request, target: String) async throws -> CommentaryArticle {
        let runtime = try self.runtime(req)
        let body = (req.body.data?.readableBytes ?? 0) > 0 ? try req.content.decode(CommentaryPublishRequest.self) : .init()
        guard let article = try await runtime.store.article(CommentaryJobService.articleID(target: target)) else { throw Abort(.notFound) }
        return try await runtime.jobs.publish(article: article, overwrite: body.overwrite == true)
    }
}
