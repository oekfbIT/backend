import Foundation
import Vapor

actor CommentaryJobService {
    let store: CommentaryStore
    let inference: AIInferenceService
    let configuration: CommentaryConfiguration
    private var processing = false

    init(store: CommentaryStore, inference: AIInferenceService, configuration: CommentaryConfiguration) {
        self.store = store; self.inference = inference; self.configuration = configuration
    }

    static func articleID(target: String, language: String = "de") -> String { CommentaryEncoding.hash("\(target):\(language)") }

    func enqueue(context: CommentaryContext, options: CommentaryGenerationOptions, now: Date = Date()) async throws -> CommentaryJob {
        try options.validate()
        try configuration.requireInference()
        if options.publish == true && context.partial && !configuration.allowPartialPublish {
            throw Abort(.conflict, reason: "Publication of partial game days is disabled.")
        }
        let target = context.targetKey + ":de"
        let key = options.idempotencyKey ?? "initial"
        let id = CommentaryEncoding.hash("\(target):\(key):\(options.dryRun == true ? "dry" : "persist")")
        if let existing = try await store.job(id) {
            guard existing.publish == (options.publish == true), existing.overwrite == (options.overwrite == true) else {
                throw Abort(.conflict, reason: "Idempotency key was already used with different options.")
            }
            return existing
        }
        let articleID = Self.articleID(target: context.targetKey)
        let existing = try await store.article(articleID)
        guard existing == nil || options.overwrite == true || options.dryRun == true else {
            throw Abort(.conflict, reason: "A draft already exists. Use overwrite=true and a new idempotency_key to regenerate.")
        }
        let job = CommentaryJob(id: id, targetKey: target, articleID: articleID, state: .pending, context: context,
            language: "de", provider: configuration.provider, model: configuration.model, promptVersion: CommentaryPromptBuilder.version,
            dryRun: options.dryRun == true, publish: options.publish == true, overwrite: options.overwrite == true,
            expectedRevision: existing?.revision ?? 0, attempts: 0, createdAt: now, updatedAt: now, availableAt: now)
        return try await store.insertJob(job)
    }

    func tick(now: Date = Date()) async throws {
        guard !processing, configuration.enabled else { return }
        processing = true
        defer { processing = false }
        let jobs = try await store.pending(now: now, limit: configuration.concurrency)
        await withTaskGroup(of: Void.self) { group in
            for (slot, job) in jobs.enumerated() {
                group.addTask {
                    do { try await self.process(job.id, slot: slot, now: now) }
                    catch { /* DB failures leave a durable lease for recovery; never log provider payloads. */ }
                }
            }
            await group.waitForAll()
        }
    }

    func process(_ id: String, slot: Int, now: Date = Date()) async throws {
        let owner = UUID().uuidString, slotID = "generation:\(slot)"
        guard try await store.acquireSlot(slotID, owner: owner, now: now, lease: configuration.leaseSeconds) else { return }
        do {
            guard var job = try await store.claim(id, owner: owner, now: now, lease: configuration.leaseSeconds, maxAttempts: configuration.maxAttempts) else {
                try await store.releaseSlot(slotID, owner: owner); return
            }
            if job.attempts > configuration.maxAttempts {
                job.state = .failed; job.lastError = "attempts_exhausted_after_restart"; job.updatedAt = Date()
                try await store.finish(job, owner: owner)
                try await store.releaseSlot(slotID, owner: owner); return
            }
            let heartbeat = Task { [store, configuration] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(configuration.leaseSeconds / 3) * 1_000_000_000)
                        try Task.checkCancellation()
                        let time = Date()
                        guard try await store.acquireSlot(slotID, owner: owner, now: time, lease: configuration.leaseSeconds) else { return }
                        try await store.renew(id, owner: owner, until: time.addingTimeInterval(Double(configuration.leaseSeconds)))
                    } catch { return }
                }
            }
            defer { heartbeat.cancel() }
            do {
                try Task.checkCancellation()
                let old = try await store.article(job.articleID)
                let generated: GeneratedCommentary
                if let old = old, old.jobID == job.id {
                    // Recover the save-article/complete-job crash window without another paid request.
                    generated = old.content
                } else {
                    guard job.dryRun || (old?.revision ?? 0) == job.expectedRevision else {
                        throw Abort(.conflict, reason: "Article changed after enqueue.")
                    }
                    var settings = configuration
                    settings.provider = job.provider; settings.model = job.model
                    let response = try await inference.generate(context: job.context, configuration: settings)
                    generated = try CommentaryValidationService.render(response, context: job.context, configuration: settings)
                    try Task.checkCancellation()
                    try await store.renew(id, owner: owner, until: Date().addingTimeInterval(Double(configuration.leaseSeconds)))
                    if !job.dryRun {
                        var content = generated
                        if job.publish && job.context.kind == .matchPreview { content.status = .published }
                        let article = CommentaryArticle(id: job.articleID, jobID: job.id, revision: job.expectedRevision + 1,
                            manuallyEdited: false, context: job.context, content: content,
                            publishedNewsID: old?.publishedNewsID, publishedContentHash: old?.publishedContentHash,
                            publishedPreview: job.publish && job.context.kind == .matchPreview ? content : (old?.publishedPreview ?? (old?.content.status == .published ? old?.content : nil)))
                        try await store.saveArticle(article, expectedRevision: job.expectedRevision)
                    }
                }
                if job.publish && !job.dryRun && job.context.kind == .gameDaySummary {
                    guard let article = try await store.article(job.articleID) else { throw Abort(.internalServerError) }
                    _ = try await publish(article: article, overwrite: job.overwrite)
                }
                if !job.dryRun, let current = try await store.article(job.articleID) { job.result = current.content }
                else { job.result = generated }
                job.state = .completed; job.lastError = nil; job.updatedAt = Date()
                try await store.finish(job, owner: owner)
            } catch {
                let failure = error as? CommentaryInferenceError
                let abort = error as? AbortError
                let retryable = failure?.retryable ?? (abort == nil || abort!.status.code >= 500)
                job.state = retryable && job.attempts < configuration.maxAttempts ? .pending : .failed
                job.lastError = failure?.code ?? (error is CancellationError ? "worker_stopped" : "context_or_storage_failure")
                job.updatedAt = Date()
                job.availableAt = job.updatedAt.addingTimeInterval(Double(failure?.retryAfter ?? min(300, 10 * (1 << job.attempts))))
                try await store.finish(job, owner: owner)
            }
            try await store.releaseSlot(slotID, owner: owner)
        } catch {
            try? await store.releaseSlot(slotID, owner: owner)
            throw error
        }
    }

    func publish(article: CommentaryArticle, overwrite: Bool) async throws -> CommentaryArticle {
        guard !article.context.partial || configuration.allowPartialPublish else {
            throw Abort(.conflict, reason: "Publication of partial game days is disabled.")
        }
        if article.context.kind == .gameDaySummary {
            return try await store.publish(article, overwrite: overwrite, now: Date())
        }
        if article.content.status == .published { return article }
        var saved = article
        saved.content.status = .published; saved.revision += 1
        saved.publishedPreview = saved.content
        try await store.saveArticle(saved, expectedRevision: article.revision)
        return saved
    }
}

/// One lightweight task in the existing Vapor process; leases bound concurrency across replicas.
final class CommentaryRuntime: @unchecked Sendable {
    let configuration: CommentaryConfiguration
    let store: CommentaryStore
    let contexts: CommentaryContextProviding
    let jobs: CommentaryJobService
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(configuration: CommentaryConfiguration, store: CommentaryStore, contexts: CommentaryContextProviding, inference: AIInferenceService) {
        self.configuration = configuration; self.store = store; self.contexts = contexts
        self.jobs = CommentaryJobService(store: store, inference: inference, configuration: configuration)
    }
    func start(logger: Logger) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil, configuration.enabled else { return }
        task = Task { [jobs, configuration] in
            while !Task.isCancelled {
                do { try await jobs.tick() }
                catch { logger.error("Commentary queue unavailable; durable jobs will retry.") }
                do { try await Task.sleep(nanoseconds: UInt64(configuration.pollSeconds) * 1_000_000_000) }
                catch { return }
            }
        }
    }
    func stop() { lock.lock(); defer { lock.unlock() }; task?.cancel(); task = nil }
}

private struct CommentaryRuntimeKey: StorageKey { typealias Value = CommentaryRuntime }
extension Application {
    var commentary: CommentaryRuntime? {
        get { storage[CommentaryRuntimeKey.self] }
        set { storage[CommentaryRuntimeKey.self] = newValue }
    }
}
struct CommentaryLifecycle: LifecycleHandler {
    func didBoot(_ application: Application) throws { application.commentary?.start(logger: application.logger) }
    func shutdown(_ application: Application) { application.commentary?.stop() }
}

func configureCommentary(_ app: Application) {
    let settings = CommentaryConfiguration.load()
    app.commentary = CommentaryRuntime(configuration: settings, store: MongoCommentaryStore(database: app.db),
        contexts: CommentaryContextBuilder(database: app.db), inference: OpenAICommentaryInference(client: app.client))
    app.lifecycle.use(CommentaryLifecycle())
}
