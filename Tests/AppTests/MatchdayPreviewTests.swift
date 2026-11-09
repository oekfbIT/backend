@testable import App
import Fluent
import FluentMongoDriver
import MongoKitten
import XCTVapor

final class MatchdayPreviewTests: XCTestCase {
    private func withFixture(allowPublish: Bool = true, _ run: (Application, CommentaryRuntime, [Match]) async throws -> Void) async throws {
        guard let port = Environment.get("COMMENTATOR_TEST_MONGO_PORT"), Int(port) != nil else { throw XCTSkip("Use isolated local MongoDB.") }
        let app = Application(.testing); app.logger.logLevel = .critical
        let name = "oekfb_preview_batch_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(name)"), as: .mongo)
        defer { try? (app.db as? MongoDatabaseRepresentable)?.raw.drop().wait(); app.shutdown() }
        let league = League(); league.id = UUID(); league.name = "Testliga"; league.code = "TEST"
        try await league.create(on: app.db)
        let season = Season(id: UUID(), leagueId: league.id, name: "2026/27", details: 1, primary: true)
        let other = Season(id: UUID(), leagueId: league.id, name: "Andere Saison", details: 1, primary: false)
        try await season.create(on: app.db); try await other.create(on: app.db)
        func team(_ name: String) -> Team {
            Team(id: UUID(), sid: name, userId: nil, leagueId: league.id, leagueCode: "TEST", points: 0,
                 coverimg: "", logo: "", teamName: name, foundationYear: nil, membershipSince: nil, averageAge: "0", coach: nil,
                 captain: nil, trikot: .init(home: "", away: ""), balance: nil, usremail: nil, usrpass: nil, usrtel: nil)
        }
        let home = team("Heim"), away = team("Gast")
        try await home.create(on: app.db); try await away.create(on: app.db)
        var matches = [Match]()
        for i in 0..<7 {
            let match = Match(id: UUID(), details: .init(gameday: i == 5 ? 2 : 1, date: i == 4 ? nil : Date().addingTimeInterval(86400), location: "Testplatz"),
                homeTeamId: home.id!, awayTeamId: away.id!, homeBlanket: .init(name: "Heim", dress: nil, logo: nil, players: []),
                awayBlanket: .init(name: "Gast", dress: nil, logo: nil, players: []), score: .init(home: 0, away: 0), status: .pending,
                bericht: "Nicht überschreiben", seasonId: i == 6 ? other.id : season.id)
            try await match.create(on: app.db); matches.append(match)
        }
        var configuration = CommentaryConfiguration()
        configuration.enabled = true; configuration.apiKey = "test-only"; configuration.model = "mock"
        configuration.serviceKey = String(repeating: "x", count: 48); configuration.allowServicePublish = allowPublish
        let runtime = CommentaryRuntime(configuration: configuration, store: MongoCommentaryStore(database: app.db),
            contexts: CommentaryContextBuilder(database: app.db), inference: MatchdayPreviewMock())
        app.commentary = runtime
        try app.register(collection: CommentatorController())
        try await run(app, runtime, matches)
    }

    func testMissingOnlyBatchSkipsArticlesAndActiveJobsAndIsSafeToRepeat() async throws {
        try await withFixture { app, runtime, matches in
            let context = try await runtime.contexts.matchPreview(matches[0].id!, now: Date())
            let existing = try await runtime.jobs.enqueue(context: context, options: .init(publish: false))
            try await runtime.jobs.process(existing.id, slot: 0)
            let pending = try await runtime.jobs.enqueue(context: runtime.contexts.matchPreview(matches[1].id!, now: Date()), options: .init())
            let service = MatchdayPreviewService(database: app.db, runtime: runtime)
            let before = try await service.overview(seasonID: matches[0].$season.id!, gameday: 1)
            XCTAssertEqual(before.total, 5); XCTAssertEqual(before.existing, 1)
            XCTAssertEqual(before.active, 1); XCTAssertEqual(before.missing, 2); XCTAssertEqual(before.unavailable, 1)
            let created = try await service.generateMissing(seasonID: matches[0].$season.id!, gameday: 1)
            XCTAssertEqual(created.queued, 2); XCTAssertEqual(created.active, 3); XCTAssertEqual(created.existing, 1)
            let repeated = try await service.generateMissing(seasonID: matches[0].$season.id!, gameday: 1)
            XCTAssertEqual(repeated.queued, 0); XCTAssertEqual(repeated.active, 3)
            let store = MongoCommentaryStore(database: app.db)
            let jobs = try await store.collection(CommentaryJob.schema).count().get()
            XCTAssertEqual(jobs, 4) // Existing draft + existing pending + two missing, no duplicates.
            let attached = try await store.article(existing.articleID)
            XCTAssertEqual(attached?.content.status, .draft)
            for item in created.items where item.state == .pending && item.jobId != pending.id {
                let job = try await store.job(item.jobId!)
                XCTAssertTrue(job?.publish == true); XCTAssertTrue(job?.overwrite == false)
                try await runtime.jobs.process(item.jobId!, slot: 0)
            }
            let after = try await service.overview(seasonID: matches[0].$season.id!, gameday: 1)
            XCTAssertEqual(after.existing, 3)
            let otherDay = try await store.article(CommentaryJobService.articleID(target: "match:\(matches[5].id!)"))
            let otherSeason = try await store.article(CommentaryJobService.articleID(target: "match:\(matches[6].id!)"))
            XCTAssertNil(otherDay); XCTAssertNil(otherSeason)
            let preserved = try await Match.find(matches[2].id!, on: app.db)
            XCTAssertEqual(preserved?.bericht, "Nicht überschreiben")
        }
    }

    func testFailedMissingJobCanBeRetriedButADryRunDoesNotBlockCreation() async throws {
        try await withFixture { app, runtime, matches in
            let context = try await runtime.contexts.matchPreview(matches[0].id!, now: Date())
            _ = try await runtime.jobs.enqueue(context: context, options: .init(dryRun: true))
            let failed = try await runtime.jobs.enqueue(context: runtime.contexts.matchPreview(matches[1].id!, now: Date()), options: .init())
            let store = MongoCommentaryStore(database: app.db)
            try await store.update(CommentaryJob.schema, query: ["_id": failed.id], changes: ["$set": ["state": "failed", "lastError": "provider_refusal"] as Document])
            let service = MatchdayPreviewService(database: app.db, runtime: runtime)
            let result = try await service.generateMissing(seasonID: matches[0].$season.id!, gameday: 1)
            XCTAssertEqual(result.queued, 4); XCTAssertEqual(result.active, 4)
            XCTAssertNotEqual(result.items.first { $0.matchId == matches[1].id }?.jobId, failed.id)
        }
    }

    func testAuthenticatedHTTPBatchAndConcurrentSubmissionLock() async throws {
        try await withFixture { app, runtime, matches in
            let path = "commenter/v1/seasons/\(matches[0].$season.id!)/gamedays/1/previews"
            try app.test(.POST, path) { XCTAssertEqual($0.status, .unauthorized) }
            try app.test(.GET, path, beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: runtime.configuration.serviceKey) }) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try $0.content.decode(MatchdayPreviewOverview.self).missing, 4)
            }
            let store = MongoCommentaryStore(database: app.db)
            let lock = "missing-previews:\(matches[0].$season.id!):1"
            _ = try await store.acquireSlot(lock, owner: "other-request", now: Date(), lease: 180)
            try app.test(.POST, path, beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: runtime.configuration.serviceKey) }) { XCTAssertEqual($0.status, .conflict) }
            try await store.releaseSlot(lock, owner: "other-request")
            try app.test(.POST, path, beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: runtime.configuration.serviceKey) }) {
                XCTAssertEqual($0.status, .accepted)
                XCTAssertEqual(try $0.content.decode(MatchdayPreviewOverview.self).queued, 4)
            }
        }
    }

    func testReadOnlyServiceCredentialCannotCreateOrPublishMissingPreviews() async throws {
        try await withFixture(allowPublish: false) { app, runtime, matches in
            let path = "commenter/v1/seasons/\(matches[0].$season.id!)/gamedays/1/previews"
            try app.test(.POST, path, beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: runtime.configuration.serviceKey) }) {
                XCTAssertEqual($0.status, .forbidden)
            }
            let count = try await MongoCommentaryStore(database: app.db).collection(CommentaryJob.schema).count().get()
            XCTAssertEqual(count, 0)
        }
    }
}

private struct MatchdayPreviewMock: AIInferenceService {
    func generate(context: CommentaryContext, configuration: CommentaryConfiguration) async throws -> CommentaryInferenceResult {
        let selection = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [context.facts.map(\.id)]), context: context, configuration: configuration)
        return .init(selection: selection, inputTokens: 1, outputTokens: 1)
    }
}
