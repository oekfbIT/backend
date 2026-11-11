@testable import App
import Crypto
import Fluent
import FluentMongoDriver
import MongoKitten
import XCTVapor

final class CommentaryTests: XCTestCase {
    private func settings() -> CommentaryConfiguration {
        var c = CommentaryConfiguration()
        c.enabled = true; c.apiKey = "test-only-never-send"; c.model = "test-model"
        c.serviceKey = String(repeating: "x", count: 48)
        return c
    }
    private func team(_ name: String, id: UUID) -> Team {
        Team(id: id, sid: name, userId: nil, leagueId: nil, leagueCode: "TEST", points: 0,
            coverimg: "", logo: "", teamName: name, foundationYear: nil, membershipSince: nil,
            averageAge: "0", coach: nil, captain: nil, trikot: Trikot(home: "", away: ""), balance: nil,
            usremail: nil, usrpass: nil, usrtel: nil)
    }
    private func fixture() -> (CommentarySeasonData, Match, Date) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = team("FC Heim", id: UUID()), away = team("FC Gast", id: UUID())
        let league = League(); league.id = UUID(); league.name = "Testliga"; league.code = "TEST"
        let season = Season(id: UUID(), leagueId: league.id, name: "2026/27", details: 1, primary: true)
        func match(days: Double, round: Int, homeGoals: Int, awayGoals: Int, reverse: Bool = false, status: GameStatus = .done) -> Match {
            let date = now.addingTimeInterval(days * 86400)
            let m = Match(id: UUID(), details: .init(gameday: round, date: date, location: "Testplatz"),
                homeTeamId: reverse ? away.id! : home.id!, awayTeamId: reverse ? home.id! : away.id!,
                homeBlanket: Blankett(name: reverse ? away.teamName : home.teamName, dress: nil, logo: nil, players: []),
                awayBlanket: Blankett(name: reverse ? home.teamName : away.teamName, dress: nil, logo: nil, players: []),
                score: .init(home: homeGoals, away: awayGoals), status: status, bericht: "Manueller Spielbericht",
                seasonId: season.id, secondHalfEndDate: status == .pending ? nil : date.addingTimeInterval(3600))
            m.$events.value = []
            return m
        }
        let past = [match(days: -10, round: 1, homeGoals: 2, awayGoals: 1),
                    match(days: -9, round: 2, homeGoals: 1, awayGoals: 1, reverse: true),
                    match(days: -8, round: 2, homeGoals: 4, awayGoals: 2),
                    match(days: -7, round: 2, homeGoals: 3, awayGoals: 1, reverse: true)]
        let target = match(days: 2, round: 3, homeGoals: 0, awayGoals: 0, status: .pending)
        let future = match(days: 5, round: 4, homeGoals: 999, awayGoals: 998)
        let data = CommentarySeasonData(season: season, league: league, teams: [home, away], matches: past + [target, future], players: [])
        return (data, target, now)
    }
    private func context() throws -> CommentaryContext {
        let (data, match, now) = fixture()
        return try CommentaryContextBuilder.preview(match: match, data: data, meetings: data.matches, now: now)
    }

    func testPreviewSchedulePreservesEnteredMatchClock() throws {
        let (data, target, _) = fixture()
        let parser = ISO8601DateFormatter()
        for (value, expected) in [
            ("2026-06-06T15:00:00Z", "06.06.2026 um 15:00 Uhr"),
            ("2026-12-06T23:30:00Z", "06.12.2026 um 23:30 Uhr")
        ] {
            target.details.date = try XCTUnwrap(parser.date(from: value))
            for offset: TimeInterval in [-86400, 86400] {
                let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: data.matches,
                    now: target.details.date!.addingTimeInterval(offset))
                let schedule = try XCTUnwrap(context.facts.first { $0.id == "schedule" })
                XCTAssertTrue(schedule.text.contains(expected), schedule.text)
            }
        }
        XCTAssertEqual(CommentaryContextBuilder.dateText(try XCTUnwrap(parser.date(from: "2026-06-06T15:00:00Z")), time: true), "06.06.2026 um 17:00 Uhr")
    }

    func testHistoricalPreviewExcludesTargetLaterAndOverlappingResults() throws {
        let (data, target, _) = fixture()
        target.status = .completed; target.score = .init(home: 777, away: 776)
        let time = target.details.date!.addingTimeInterval(10 * 86400)
        let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: data.matches, now: time)
        let text = context.facts.map(\.text).joined(separator: " ")
        XCTAssertTrue(context.historical)
        XCTAssertFalse(text.contains("777")); XCTAssertFalse(text.contains("999"))
        XCTAssertFalse(text.contains("Angesetzt ist"))
        XCTAssertFalse(context.facts.contains { $0.id.contains("suspended") })
        let overlapping = data.matches[0]
        overlapping.details.date = target.details.date!.addingTimeInterval(-120)
        overlapping.secondHalfEndDate = target.details.date!.addingTimeInterval(3600)
        XCTAssertFalse(CommentaryContextBuilder.resultKnown(overlapping, before: target.details.date!))
    }

    func testFixtureSpecificSuspensionAndHistoricalOmission() throws {
        let (base, target, now) = fixture()
        let player = Player(id: UUID(), sid: "p", image: nil, team_oeid: nil, email: "private@example.com", name: "Max Spieler",
            number: "9", birthday: "1990-01-01", teamID: target.$homeTeam.id, nationality: "AT", position: "Sturm",
            eligibility: .Gesperrt, registerDate: "", identification: "private-document", status: true, blockdate: now.addingTimeInterval(86400))
        func build() throws -> CommentaryContext {
            let data = CommentarySeasonData(season: base.season, league: base.league, teams: base.teams, matches: base.matches, players: [player])
            return try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        }
        XCTAssertFalse(try build().facts.contains { $0.id.contains("suspended") })
        player.blockdate = target.details.date!.addingTimeInterval(3600)
        let snapshot = try build()
        XCTAssertTrue(snapshot.facts.contains { $0.id.contains("suspended") })
        let json = String(decoding: try CommentaryEncoding.encoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(json.contains("private@example.com")); XCTAssertFalse(json.contains("private-document"))
        target.status = .first
        XCTAssertFalse(try build().facts.contains { $0.id.contains("suspended") })
    }

    func testIncompleteRoundRequiresExplicitPartialAndLabelsIt() throws {
        let (base, _, now) = fixture()
        base.matches[1].status = .first
        XCTAssertThrowsError(try CommentaryContextBuilder.summary(data: base, gameday: 2, allowPartial: false, now: now))
        let context = try CommentaryContextBuilder.summary(data: base, gameday: 2, allowPartial: true, now: now)
        XCTAssertTrue(context.partial)
        XCTAssertTrue(context.requiredFactIDs.contains("partial"))
        XCTAssertTrue(context.titles[0].contains("Zwischenstand"))
        XCTAssertFalse(context.facts.map(\.text).joined().contains("999"))
        XCTAssertThrowsError(try CommentaryContextBuilder.summary(data: base, gameday: 99, allowPartial: true, now: now))
    }

    func testWeeklyReportSkipsPendingAndExplainsAbandonedGames() throws {
        let (data, _, now) = fixture()
        let target = data.matches[1]
        target.status = .pending
        let skipped = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
        XCTAssertFalse(skipped.partial)
        XCTAssertFalse(skipped.requiredFactIDs.contains("result.\(target.id!)"))
        for status: GameStatus in [.abbgebrochen, .cancelled] {
            target.status = status
            let report = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
            XCTAssertFalse(report.partial)
            let fact = try XCTUnwrap(report.facts.first { $0.id == "result.\(target.id!)" })
            XCTAssertTrue(fact.text.contains(status == .abbgebrochen ? "Weitere Informationen" : "abgesagt oder verschoben"))
            XCTAssertFalse(report.sectionHeadings?["match.\(target.id!)"]?.contains(":") == true)
        }
    }

    func testAwardedMatchIsNotDescribedAsPlayedGoals() throws {
        let (data, _, now) = fixture()
        data.matches[1].status = .cancelled; data.matches[1].score = .init(home: 6, away: 0)
        let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
        let fact = try XCTUnwrap(context.facts.first { $0.id == "result.\(data.matches[1].id!)" })
        XCTAssertTrue(fact.text.contains("abgesagt oder verschoben"))
        XCTAssertTrue(context.facts.first { $0.id == "totals" }!.text.contains("10 Tore"))
    }

    func testUnknownFactsWrongLanguageDuplicatesAndHTMLAreRejectedOrEscaped() throws {
        let context = try context()
        let good = CommentaryMockInference.selection(context)
        var result = CommentaryInferenceResult(selection: good, inputTokens: 20, outputTokens: 30)
        XCTAssertNoThrow(try CommentaryValidationService.render(result, context: context, configuration: settings()))
        for selection in [CommentarySelection(titleIndex: 0, language: "en", paragraphs: good.paragraphs),
                          .init(titleIndex: 0, language: "de", paragraphs: good.paragraphs + [["invented-injury"]]),
                          .init(titleIndex: 0, language: "de", paragraphs: good.paragraphs + [["fixture"]]),
                          .init(titleIndex: 10, language: "de", paragraphs: good.paragraphs),
                          .init(titleIndex: 0, language: "de", paragraphs: [["schedule"]])] {
            result = .init(selection: selection, inputTokens: 0, outputTokens: 0)
            XCTAssertThrowsError(try CommentaryValidationService.render(result, context: context, configuration: settings()))
        }
        XCTAssertEqual(CommentaryEncoding.html("<script>\"&'"), "&lt;script&gt;&quot;&amp;&#39;")
    }

    func testMissingStatisticsProduceShortGroundedPreview() throws {
        let (base, target, now) = fixture()
        let data = CommentarySeasonData(season: base.season, league: base.league, teams: base.teams, matches: [target], players: [])
        let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        let result = CommentaryInferenceResult(selection: .init(titleIndex: 0, language: "de", paragraphs: [context.facts.map(\.id)]), inputTokens: 0, outputTokens: 0)
        let article = try CommentaryValidationService.render(result, context: context, configuration: settings())
        XCTAssertFalse(article.text.isEmpty); XCTAssertLessThan(article.text.split(separator: " ").count, 150)
        XCTAssertFalse(article.text.contains("Sieg"))
    }

    func testRequiredFramingIsInsertedAndDuplicateReferencesAreRemovedWithoutAcceptingUnknownFacts() throws {
        let context = try context()
        let original = CommentaryMockInference.selection(context)
        let missing = CommentarySelection(titleIndex: 0, language: "de", paragraphs: original.paragraphs.map { $0.filter { $0 != "fixture" } } + [["home.form"]])
        let normalized = CommentaryValidationService.normalize(missing, context: context)
        XCTAssertEqual(normalized.paragraphs.flatMap { $0 }.filter { $0 == "fixture" }.count, 1)
        XCTAssertEqual(normalized.paragraphs.flatMap { $0 }.filter { $0 == "home.form" }.count, 1)
        XCTAssertNoThrow(try CommentaryValidationService.render(.init(selection: normalized, inputTokens: 0, outputTokens: 0), context: context, configuration: settings()))
        let unknown = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [["invented-injury"]]), context: context)
        XCTAssertThrowsError(try CommentaryValidationService.render(.init(selection: unknown, inputTokens: 0, outputTokens: 0), context: context, configuration: settings()))
    }

    func testEditorialWordBudgetUsesWholeVerifiedSentencesForLongAndThinModelSelections() throws {
        let context = try context()
        for ids in [context.facts.map(\.id), ["fixture"]] {
            let normalized = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [ids]), context: context, configuration: settings())
            let rendered = try CommentaryValidationService.render(.init(selection: normalized, inputTokens: 0, outputTokens: 0), context: context, configuration: settings())
            let count = rendered.text.split(whereSeparator: \.isWhitespace).count
            XCTAssertGreaterThanOrEqual(count, 25); XCTAssertLessThanOrEqual(count, settings().maxPreviewWords)
            XCTAssertTrue(rendered.factIDs.contains("fixture"))
            XCTAssertTrue(Set(rendered.factIDs).isSubset(of: Set(context.facts.map(\.id))))
        }
    }

    func testConfigurationFailsClosedAndNoCredentialsAreHardcoded() throws {
        let c = CommentaryConfiguration.load { _ in nil }
        XCTAssertFalse(c.enabled); XCTAssertTrue(c.apiKey.isEmpty); XCTAssertTrue(c.model.isEmpty)
        XCTAssertThrowsError(try c.requireInference())
        let values = ["COMMENTATOR_ENABLED": "true", "COMMENTATOR_CONCURRENCY": "999", "COMMENTATOR_MAX_ATTEMPTS": "0"]
        let bounded = CommentaryConfiguration.load { values[$0] }
        XCTAssertEqual(bounded.concurrency, 5); XCTAssertEqual(bounded.maxAttempts, 1)
        var options = CommentaryGenerationOptions(overwrite: true)
        XCTAssertThrowsError(try options.validate())
        options.idempotencyKey = "revision-2"; XCTAssertNoThrow(try options.validate())
        options.dryRun = true; options.publish = true; XCTAssertThrowsError(try options.validate())
    }

    func testOpenAIAdapterUsesStructuredOutputNoStorageAndNeverAcceptsTruncation() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let context = try context()
        let client = CommentaryMockClient(eventLoop: app.eventLoopGroup.next(), context: context)
        let result = try await OpenAICommentaryInference(client: client).generate(context: context, configuration: settings())
        XCTAssertEqual(result.inputTokens, 25)
        let request = try XCTUnwrap(client.request)
        XCTAssertEqual(request.url.path, "/v1/responses")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: request.body!)) as? [String: Any])
        XCTAssertEqual(json["store"] as? Bool, false)
        let format = try XCTUnwrap((json["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema"); XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(request.timeout, .seconds(60))
        for (status, truncated, retryable) in [(HTTPStatus.tooManyRequests, false, true), (.internalServerError, false, true), (.unauthorized, false, false), (.ok, true, false)] {
            let bad = CommentaryMockClient(eventLoop: app.eventLoopGroup.next(), context: context, status: status, truncated: truncated)
            do { _ = try await OpenAICommentaryInference(client: bad).generate(context: context, configuration: settings()); XCTFail("Expected failure") }
            catch let error as CommentaryInferenceError { XCTAssertEqual(error.retryable, retryable); XCTAssertFalse(error.code.contains("test-only")) }
        }
        let timeout = CommentaryMockClient(eventLoop: app.eventLoopGroup.next(), context: context, transportFailure: true)
        do { _ = try await OpenAICommentaryInference(client: timeout).generate(context: context, configuration: settings()); XCTFail("Expected timeout") }
        catch let error as CommentaryInferenceError { XCTAssertTrue(error.retryable) }
    }

    func testServiceAuthenticationAndPublicationPermissions() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        app.commentary = CommentaryRuntime(configuration: settings(), store: UnavailableCommentaryStore(), contexts: CommentaryStubContext(context: try context()), inference: CommentaryMockInference())
        try app.register(collection: CommentatorController())
        let id = UUID().uuidString
        for path in ["commenter/v1/generate/match/\(id)/status", "commenter/v1/context/match/\(id)", "commenter/v1/jobs/test"] {
            try app.test(.GET, path) { XCTAssertEqual($0.status, .unauthorized) }
        }
        try app.test(.GET, "commenter/v1/seasons/\(id)/news") { XCTAssertEqual($0.status, .unauthorized) }
        try app.test(.GET, "commenter/v1/context/match/\(id)", beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: "wrong") }) { XCTAssertEqual($0.status, .unauthorized) }
        try app.test(.GET, "commenter/v1/context/match/\(id)", beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey) }) { XCTAssertEqual($0.status, .ok) }
        try app.test(.POST, "commenter/v1/generate/gameday/\(id)/2/publish", beforeRequest: { $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey) }) { XCTAssertEqual($0.status, .forbidden) }
        try app.test(.POST, "commenter/v1/generate/match/\(id)", beforeRequest: {
            $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey)
            try $0.content.encode(CommentaryGenerationOptions(publish: true))
        }) { XCTAssertEqual($0.status, .forbidden) }
        try app.test(.POST, "commenter/v1/generate/match/\(id)", beforeRequest: {
            $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey)
        }) { XCTAssertEqual($0.status, .forbidden) } // Omitted publish means publication, never a bypass.
        let readOnly = User(userID: "test", type: .admin, firstName: "Test", lastName: "Admin", email: "test@example.com", passwordHash: "unused")
        readOnly.permissions = [.analyticsRead]
        let req = Request(application: app, on: app.eventLoopGroup.next()); req.auth.login(readOnly)
        do { _ = try await CommentaryAccessMiddleware(configuration: settings()).respond(to: req, chainingTo: CommentaryTestResponder()); XCTFail("Expected permission denial") }
        catch let error as AbortError { XCTAssertEqual(error.status, .forbidden) }
        readOnly.permissions = [.contentManage]
        let permitted = try await CommentaryAccessMiddleware(configuration: settings()).respond(to: req, chainingTo: CommentaryTestResponder())
        XCTAssertEqual(permitted.status, .ok)
    }

    func testSuccessfulGenerationDurableIdempotencyAndReportPreservation() async throws {
        try await withMongo { app, store in
            let (data, target, time) = self.fixture()
            let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: data.matches, now: time)
            let mock = CommentaryMockInference()
            try await target.create(on: app.db)
            let service = CommentaryJobService(store: store, inference: mock, configuration: self.settings())
            let job = try await service.enqueue(context: context, options: .init())
            let repeatJob = try await service.enqueue(context: context, options: .init())
            XCTAssertEqual(job.id, repeatJob.id)
            try await service.process(job.id, slot: 0)
            try await service.process(job.id, slot: 0)
            let saved = try await store.job(job.id), article = try await store.article(job.articleID)
            XCTAssertEqual(saved?.state, .completed); XCTAssertEqual(article?.content.status, .published)
            XCTAssertEqual(article?.publishedPreview?.status, .published)
            let calls = await mock.calls; XCTAssertEqual(calls, 1)
            let newsCount = try await store.collection(NewsItem.schema).count().get()
            XCTAssertEqual(newsCount, 0)
            // The production service never writes Match; preserve its actual stored report too.
            let before = try await Match.find(target.id!, on: app.db)
            XCTAssertEqual(before?.bericht, "Manueller Spielbericht")
            XCTAssertEqual(data.matches.last?.score.home, 999)
        }
    }

    func testRetriesRateLimitThenSuccessAndTerminalInvalidOutput() async throws {
        try await withMongo { _, store in
            let context = try self.context()
            let mock = CommentaryMockInference(failures: [.init(code: "provider_http_429", retryable: true)])
            let service = CommentaryJobService(store: store, inference: mock, configuration: self.settings())
            let job = try await service.enqueue(context: context, options: .init())
            try await service.process(job.id, slot: 0)
            let pending = try await store.job(job.id)
            XCTAssertEqual(pending?.state, .pending); XCTAssertEqual(pending?.attempts, 1)
            try await service.process(job.id, slot: 0, now: Date().addingTimeInterval(120))
            let saved = try await store.job(job.id)
            XCTAssertEqual(saved?.state, .completed); XCTAssertEqual(saved?.attempts, 2)
            let bad = CommentaryMockInference(invalid: true)
            let invalidService = CommentaryJobService(store: store, inference: bad, configuration: self.settings())
            let invalid = try await invalidService.enqueue(context: context, options: .init(overwrite: true, idempotencyKey: "bad"))
            try await invalidService.process(invalid.id, slot: 1)
            let failed = try await store.job(invalid.id)
            XCTAssertEqual(failed?.state, .failed)
            XCTAssertEqual(failed?.lastError, "unsupported_or_missing_fact")
        }
    }

    func testRestartLeaseRecoveryAndGlobalSlotLimit() async throws {
        try await withMongo { _, store in
            let mock = CommentaryMockInference(), context = try self.context()
            let first = CommentaryJobService(store: store, inference: mock, configuration: self.settings())
            let job = try await first.enqueue(context: context, options: .init())
            let now = Date()
            let claim = try await store.claim(job.id, owner: "dead-process", now: now, lease: 1, maxAttempts: 3)
            XCTAssertNotNil(claim)
            let second = CommentaryJobService(store: store, inference: mock, configuration: self.settings())
            try await second.process(job.id, slot: 0, now: now.addingTimeInterval(2))
            let recovered = try await store.job(job.id)
            XCTAssertEqual(recovered?.state, .completed); XCTAssertEqual(recovered?.attempts, 2)
            let acquired = try await store.acquireSlot("limit", owner: "a", now: now, lease: 60)
            let denied = try await store.acquireSlot("limit", owner: "b", now: now, lease: 60)
            XCTAssertTrue(acquired); XCTAssertFalse(denied)
        }
    }

    func testManualEditsArePreservedAndDryRunDoesNotPersistArticle() async throws {
        try await withMongo { _, store in
            let context = try self.context(), mock = CommentaryMockInference()
            let service = CommentaryJobService(store: store, inference: mock, configuration: self.settings())
            let dry = try await service.enqueue(context: context, options: .init(dryRun: true))
            try await service.process(dry.id, slot: 0)
            let absent = try await store.article(dry.articleID)
            XCTAssertNil(absent)
            let initial = try await service.enqueue(context: context, options: .init())
            try await service.process(initial.id, slot: 0)
            let regen = try await service.enqueue(context: context, options: .init(overwrite: true, idempotencyKey: "next"))
            let storedArticle = try await store.article(initial.articleID)
            var article = try XCTUnwrap(storedArticle)
            article.revision += 1; article.manuallyEdited = true
            try await store.saveArticle(article, expectedRevision: article.revision - 1)
            try await service.process(regen.id, slot: 0)
            let preserved = try await store.article(initial.articleID), failed = try await store.job(regen.id)
            XCTAssertTrue(preserved?.manuallyEdited == true); XCTAssertEqual(failed?.state, .failed)
        }
    }

    func testDeletePreviewRemovesPublicSnapshotAndAllowsRegeneration() async throws {
        try await withMongo { _, store in
            let context = try self.context()
            let service = CommentaryJobService(store: store, inference: CommentaryMockInference(), configuration: self.settings())
            let job = try await service.enqueue(context: context, options: .init())
            try await service.process(job.id, slot: 0)
            let stored = try await store.article(job.articleID)
            let article = try XCTUnwrap(stored)
            XCTAssertNotNil(article.publishedPreview)
            do {
                try await store.deletePreview(article.id, expectedRevision: article.revision + 1)
                XCTFail("Stale deletion must fail")
            } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
            let regeneration = try await service.enqueue(context: context, options: .init(overwrite: true, idempotencyKey: "busy"))
            do {
                try await store.deletePreview(article.id, expectedRevision: article.revision)
                XCTFail("Active generation must block deletion")
            } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
            try await service.process(regeneration.id, slot: 0)
            let updated = try await store.article(article.id)
            try await store.deletePreview(article.id, expectedRevision: try XCTUnwrap(updated).revision)
            let absent = try await store.article(article.id)
            XCTAssertNil(absent)
            let next = try await service.enqueue(context: context, options: .init(idempotencyKey: "after-delete"))
            try await service.process(next.id, slot: 0)
            let recreated = try await store.article(article.id)
            XCTAssertNotNil(recreated?.publishedPreview)
        }
    }

    func testSavedArticleCrashWindowRecoversWithoutAnotherModelRequest() async throws {
        try await withMongo { _, store in
            let context = try self.context(), mock = CommentaryMockInference()
            let service = CommentaryJobService(store: store, inference: mock, configuration: self.settings())
            let job = try await service.enqueue(context: context, options: .init())
            let now = Date()
            _ = try await store.claim(job.id, owner: "crashed", now: now, lease: 1, maxAttempts: 3)
            let rendered = try CommentaryValidationService.render(.init(selection: CommentaryMockInference.selection(context), inputTokens: 1, outputTokens: 1), context: context, configuration: self.settings())
            let article = CommentaryArticle(id: job.articleID, jobID: job.id, revision: 1, manuallyEdited: false, context: context, content: rendered)
            try await store.saveArticle(article, expectedRevision: 0)
            try await service.process(job.id, slot: 0, now: now.addingTimeInterval(2))
            let saved = try await store.job(job.id), calls = await mock.calls
            XCTAssertEqual(saved?.state, .completed); XCTAssertEqual(calls, 0)
            let recovered = try await store.article(job.articleID)
            XCTAssertEqual(recovered?.publishedPreview?.status, .published)
        }
    }

    func testWeeklySummaryDraftExplicitPublicationAndDuplicateProtection() async throws {
        try await withMongo { app, store in
            let (data, _, now) = self.fixture()
            let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
            let service = CommentaryJobService(store: store, inference: CommentaryMockInference(), configuration: self.settings())
            let job = try await service.enqueue(context: context, options: .init(publish: false))
            try await service.process(job.id, slot: 0)
            let beforeCount = try await store.collection(NewsItem.schema).count().get(); XCTAssertEqual(beforeCount, 0)
            let storedDraft = try await store.article(job.articleID)
            let draft = try XCTUnwrap(storedDraft)
            let published = try await service.publish(article: draft, overwrite: false)
            let storedCurrent = try await store.article(job.articleID)
            let current = try XCTUnwrap(storedCurrent)
            let repeated = try await service.publish(article: current, overwrite: false)
            XCTAssertEqual(published.publishedNewsID, repeated.publishedNewsID)
            let count = try await store.collection(NewsItem.schema).count().get(); XCTAssertEqual(count, 1)
            let news = try await NewsItem.find(published.publishedNewsID!, on: app.db)
            XCTAssertEqual(news?.tag, "TEST"); XCTAssertTrue(news?.text?.hasPrefix("<p>") == true)
            XCTAssertEqual(news?.image, NewsItem.defaultImageURL); XCTAssertNil(news?.matchID)
            let customImage = "https://www.oekfb.eu/editor-selected.jpg"
            news?.image = customImage; try await news?.save(on: app.db)
            let imageArticle = try await store.article(job.articleID)
            _ = try await service.publish(article: XCTUnwrap(imageArticle), overwrite: false)
            let republished = try await NewsItem.find(published.publishedNewsID!, on: app.db)
            XCTAssertEqual(republished?.image, customImage)
            let key = try BSONEncoder().encodePrimitive(published.publishedNewsID!)!
            try await store.update(NewsItem.schema, query: ["_id": key], changes: ["$set": ["text": "Manuell bearbeitet"]])
            let storedSaved = try await store.article(job.articleID)
            let saved = try XCTUnwrap(storedSaved)
            do { _ = try await service.publish(article: saved, overwrite: false); XCTFail("Expected manual edit protection") }
            catch let error as AbortError { XCTAssertEqual(error.status, .conflict) }
        }
    }

    func testDatabaseFailureDoesNotBecomeSuccessfulEmptyGeneration() async throws {
        let service = CommentaryJobService(store: UnavailableCommentaryStore(), inference: CommentaryMockInference(), configuration: settings())
        do { _ = try await service.enqueue(context: context(), options: .init()); XCTFail("Expected DB failure") }
        catch let error as AbortError { XCTAssertEqual(error.status, .serviceUnavailable) }
    }

    func testBothTeamFormsExcludeTheTargetAndLaterResults() {
        let (data, target, now) = fixture()
        target.status = .done
        target.score = .init(home: 777, away: 0)
        let form = MatchTeamFormService.forms(for: target, history: data.matches, now: now.addingTimeInterval(30 * 86400))
        XCTAssertEqual(form.home.count, 4); XCTAssertEqual(form.away.count, 4)
        XCTAssertFalse(form.home.contains { $0.matchID == target.id })
        XCTAssertFalse(form.home.contains { $0.score?.home == 999 })
        XCTAssertEqual(form.home.first?.result, .L)
        XCTAssertEqual(form.away.first?.result, .W)
    }

    func testPublishedPreviewSurvivesRegenerationUntilReplacementIsPublished() async throws {
        try await withMongo { _, store in
            let context = try self.context()
            let service = CommentaryJobService(store: store, inference: CommentaryMockInference(), configuration: self.settings())
            let first = try await service.enqueue(context: context, options: .init())
            try await service.process(first.id, slot: 0)
            let initial = try await store.article(first.articleID)
            let published = try await service.publish(article: XCTUnwrap(initial), overwrite: false)
            XCTAssertEqual(published.publishedPreview?.status, .published)
            let next = try await service.enqueue(context: context, options: .init(publish: false, overwrite: true, idempotencyKey: "replacement"))
            try await service.process(next.id, slot: 0)
            let replacement = try await store.article(first.articleID)
            XCTAssertEqual(replacement?.content.status, .draft)
            XCTAssertEqual(replacement?.publishedPreview?.generatedAt, published.content.generatedAt)
        }
    }

    func testHTTPGenerationStatusDryRunAndBatchBounds() async throws {
        try await withMongo { app, store in
            let context = try self.context(), mock = CommentaryMockInference()
            let runtime = CommentaryRuntime(configuration: self.settings(), store: store, contexts: CommentaryStubContext(context: context), inference: mock)
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            let path = "commenter/v1/generate/match/\(context.matchID!)"
            var jobID: String?
            try app.test(.POST, path, beforeRequest: {
                $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey)
                try $0.content.encode(CommentaryGenerationOptions(dryRun: true))
            }) {
                XCTAssertEqual($0.status, .accepted)
                jobID = try $0.content.decode(CommentaryJob.self).id
            }
            let id = try XCTUnwrap(jobID)
            try await runtime.jobs.process(id, slot: 0)
            try app.test(.GET, "commenter/v1/jobs/\(id)", beforeRequest: {
                $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey)
            }) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try $0.content.decode(CommentaryJob.self).state, .completed)
            }
            try app.test(.GET, "webClient/match/\(context.matchID!)/preview") { XCTAssertEqual($0.status, .notFound) }
            try app.test(.POST, "commenter/v1/generate/matches/batch", beforeRequest: {
                $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey)
                try $0.content.encode(CommentaryBatchRequest(matchIds: Array(repeating: UUID(), count: 151), options: .init(publish: false)))
            }) { XCTAssertEqual($0.status, .badRequest) }
        }
    }

    func testProgrammaticWeeklySummaryPublishesOnceWithoutApproval() async throws {
        try await withMongo { app, store in
            let (data, _, now) = self.fixture()
            let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
            var settings = self.settings(); settings.allowServicePublish = true
            let mock = CommentaryMockInference()
            let runtime = CommentaryRuntime(configuration: settings, store: store, contexts: CommentaryStubContext(context: context), inference: mock)
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            var jobID: String?
            for _ in 0..<2 {
                try app.test(.POST, "commenter/v1/generate/gameday", beforeRequest: {
                    $0.headers.add(name: "X-Commentator-Key", value: settings.serviceKey)
                    try $0.content.encode(CommentaryGameDayRequest(seasonId: context.seasonID, gameday: 2))
                }) {
                    XCTAssertEqual($0.status, .accepted)
                    let job = try $0.content.decode(CommentaryJob.self)
                    XCTAssertTrue(job.publish)
                    if let previous = jobID { XCTAssertEqual(previous, job.id) }
                    jobID = job.id
                }
                try await runtime.jobs.process(XCTUnwrap(jobID), slot: 0)
            }
            let job = try await store.job(XCTUnwrap(jobID))
            XCTAssertEqual(job?.state, .completed)
            XCTAssertEqual(job?.result?.status, .published)
            let article = try await store.article(XCTUnwrap(job?.articleID))
            let news = try await NewsItem.find(XCTUnwrap(article?.publishedNewsID), on: app.db)
            XCTAssertEqual(news?.title, article?.content.title)
            let count = try await store.collection(NewsItem.schema).count().get()
            XCTAssertEqual(count, 1)
            let calls = await mock.calls; XCTAssertEqual(calls, 1)
        }
    }

    func testPublishedEditsUpdatePublicPreviewAndRejectStaleRevision() async throws {
        try await withMongo { app, store in
            let context = try self.context()
            var settings = self.settings(); settings.allowServicePublish = true
            let runtime = CommentaryRuntime(configuration: settings, store: store, contexts: CommentaryStubContext(context: context), inference: CommentaryMockInference())
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            let job = try await runtime.jobs.enqueue(context: context, options: .init())
            try await runtime.jobs.process(job.id, slot: 0)
            let initial = try await store.article(job.articleID)
            let revision = try XCTUnwrap(initial?.revision)
            for expected in [HTTPResponseStatus.ok, .conflict] {
                try app.test(.PATCH, "commenter/v1/articles/\(job.articleID)", beforeRequest: {
                    $0.headers.add(name: "X-Commentator-Key", value: settings.serviceKey)
                    // No publish flag: an edit of published content stays public.
                    try $0.content.encode(CommentaryEditRequest(expectedRevision: revision, title: "Korrigierte Überschrift", text: "Manuell korrigierter Vorbericht."))
                }) { XCTAssertEqual($0.status, expected) }
            }
            try app.test(.GET, "webClient/match/\(context.matchID!)/preview") {
                XCTAssertEqual($0.status, .ok)
                let content = try $0.content.decode(GeneratedCommentary.self)
                XCTAssertEqual(content.text, "Manuell korrigierter Vorbericht.")
                XCTAssertEqual(content.status, .published)
            }
            let edited = try await store.article(job.articleID)
            XCTAssertTrue(edited?.manuallyEdited == true)
        }
    }

    func testDefaultPublicationModesAndPartialRoundProtection() async throws {
        XCTAssertTrue(CommentaryGenerationOptions().shouldPublish)
        XCTAssertFalse(CommentaryGenerationOptions(publish: false).shouldPublish)
        XCTAssertFalse(CommentaryGenerationOptions(dryRun: true).shouldPublish)
        let (data, _, now) = fixture()
        data.matches.first { $0.details.gameday == 2 }?.status = .first
        let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: true, now: now)
        XCTAssertTrue(context.partial)
        let service = CommentaryJobService(store: UnavailableCommentaryStore(), inference: CommentaryMockInference(), configuration: settings())
        do { _ = try await service.enqueue(context: context, options: .init()); XCTFail("Must not publish an incomplete round by default") }
        catch let error as AbortError { XCTAssertEqual(error.status, .conflict) }
    }

    func testPublishedNewsEditsUpdateExistingStoryWithoutAnotherApproval() async throws {
        try await withMongo { app, store in
            let (data, _, now) = self.fixture()
            let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
            var settings = self.settings(); settings.allowServicePublish = true
            let runtime = CommentaryRuntime(configuration: settings, store: store, contexts: CommentaryStubContext(context: context), inference: CommentaryMockInference())
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            let job = try await runtime.jobs.enqueue(context: context, options: .init())
            try await runtime.jobs.process(job.id, slot: 0)
            let article = try await store.article(job.articleID)
            let revision = try XCTUnwrap(article?.revision)
            let newsID = try XCTUnwrap(article?.publishedNewsID)
            try app.test(.PATCH, "commenter/v1/articles/\(job.articleID)", beforeRequest: {
                $0.headers.add(name: "X-Commentator-Key", value: settings.serviceKey)
                try $0.content.encode(CommentaryEditRequest(expectedRevision: revision, title: "Spieltag korrigiert", text: "Redaktionell ergänzte Zusammenfassung."))
            }) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try $0.content.decode(CommentaryArticle.self).content.status, .published)
            }
            let news = try await NewsItem.find(newsID, on: app.db)
            XCTAssertEqual(news?.title, "Spieltag korrigiert")
            XCTAssertEqual(news?.text, "<p>Redaktionell ergänzte Zusammenfassung.</p>")
            let count = try await store.collection(NewsItem.schema).count().get()
            XCTAssertEqual(count, 1)
        }
    }

    func testTopTenMilestoneRequiresReconciledGoalsAndUsesSharedRanks() throws {
        let (data, target, now) = fixture()
        let previous = Array(data.matches.prefix(4))
        previous.forEach { $0.score = .init(home: 0, away: 0); $0.$events.value = [] }
        let match = previous[0], hero = UUID()
        var events = [MatchEvent(id: UUID(), matchId: match.id!, type: .goal, playerId: hero, minute: 1, name: "Top-Ten-Kandidat", image: nil, number: nil, assign: .home)]
        for i in 0..<10 {
            let id = UUID()
            for minute in 1...2 {
                events.append(MatchEvent(id: UUID(), matchId: match.id!, type: .goal, playerId: id, minute: minute, name: "Torjäger \(i)", image: nil, number: nil, assign: .away))
            }
        }
        match.score = .init(home: 1, away: 20); match.$events.value = events
        let race = CommentaryContextBuilder.scorerRace(previous)
        XCTAssertTrue(race.complete)
        let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        let milestone = try XCTUnwrap(context.facts.first { $0.id == "home.milestone.\(hero)" })
        XCTAssertTrue(milestone.text.contains("beim jetzigen Stand"))
        XCTAssertTrue(milestone.text.contains("geteilten Top-10-Platz"))
        XCTAssertFalse(milestone.sourceIDs.contains(target.id!.uuidString))
        let repeated = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        XCTAssertEqual(try context.contextHash, try repeated.contextHash)
        match.score.home += 1 // A missing goal event invalidates a purported league-wide rank.
        let incomplete = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        XCTAssertFalse(incomplete.facts.contains { $0.id.contains(".milestone.") })
    }

    func testScorerLeaderGapNamesTheLeaderAndOwnGoalsDoNotCountForPlayers() throws {
        let (data, _, _) = fixture()
        let match = data.matches[0], challenger = UUID(), leader = UUID()
        var events = [MatchEvent]()
        for (id, name, side, count) in [(challenger, "Angreifer", MatchAssignment.home, 5), (leader, "Spitzenreiter", .away, 6)] {
            for minute in 1...count {
                events.append(MatchEvent(id: UUID(), matchId: match.id!, type: .goal, playerId: id, minute: minute, name: name, image: nil, number: nil, assign: side))
            }
        }
        events.append(MatchEvent(id: UUID(), matchId: match.id!, type: .goal, playerId: challenger, minute: 20, name: "Angreifer", image: nil, number: nil, assign: .away, ownGoal: true))
        match.$events.value = events; match.score = .init(home: 5, away: 7)
        let race = CommentaryContextBuilder.scorerRace([match])
        XCTAssertTrue(race.complete)
        XCTAssertEqual(race.rows.first { $0.id == challenger }?.goals, 5)
        let facts = CommentaryContextBuilder.playerAngles(teamID: match.$homeTeam.id, teamName: "Heim", matches: [match], players: [], label: "home")
        let milestone = try XCTUnwrap(facts.first { $0.id.contains("milestone") })
        XCTAssertTrue(milestone.text.contains("fehlt noch ein Treffer"))
        XCTAssertTrue(milestone.text.contains("Spitzenreiter"))
        XCTAssertTrue(milestone.text.contains("(6)"))
        XCTAssertFalse(CommentaryContextBuilder.playerAngles(teamID: match.$homeTeam.id, teamName: "Heim", matches: [match], players: [], label: "home", excludedPlayers: [challenger]).contains { $0.id.contains("milestone") })
    }

    func testCardHistoryUsesRecordedCardsAtCutoffAndNeverInfersFoulsOrSuspensions() throws {
        let (data, target, now) = fixture()
        let player = UUID(), homeID = target.$homeTeam.id
        for match in data.matches {
            let side: MatchAssignment = match.$homeTeam.id == homeID ? .home : .away
            let card = MatchEvent(id: UUID(), matchId: match.id!, type: .yellowCard, playerId: player, minute: 10, name: "Karten-Spieler", image: nil, number: nil, assign: side)
            let freeKick = MatchEvent(id: UUID(), matchId: match.id!, type: .freeKick, playerId: player, minute: 11, name: "Karten-Spieler", image: nil, number: nil, assign: side)
            match.$events.value = [card, card, freeKick] // Duplicate event IDs count once.
        }
        let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        let fact = try XCTUnwrap(context.facts.first { $0.id == "home.discipline.\(player)" })
        XCTAssertTrue(fact.text.contains("4 Gelbe Karten"))
        XCTAssertFalse(fact.text.contains("6 Gelbe"))
        XCTAssertFalse(fact.text.contains("Foul")); XCTAssertFalse(fact.text.contains("gesperrt"))
        XCTAssertFalse(fact.sourceIDs.contains(target.id!.uuidString))
        for id in [target.id!, data.matches.last!.id!] { XCTAssertFalse(fact.sourceIDs.contains(id.uuidString)) }
    }

    func testAwardedScoresStayInRecordsButNeverBecomePlayedAttackOrDefenceGoals() throws {
        let (data, target, now) = fixture()
        data.matches[0].status = .cancelled; data.matches[0].score = .init(home: 600, away: 0)
        let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        let home = context.facts.filter { $0.group == "home" && ["home.form", "home.split", "home.attack", "home.defence"].contains($0.id) }
        XCTAssertFalse(home.isEmpty)
        XCTAssertFalse(home.map(\.text).joined().contains("600"))
        XCTAssertTrue(home.first { $0.id == "home.form" }?.text.contains("Wertung") == true)
        XCTAssertTrue(home.first { $0.id == "home.form" }?.text.contains("3 gespielten Partien") == true)
    }

    func testPreviewSelectionAvoidsRepeatedTopicsAndRespectsConfiguredLimit() throws {
        let context = try context()
        var configuration = settings(); configuration.maxPreviewWords = 250
        let requested = ["fixture", "home.form", "home.streak", "home.table", "away.form", "away.table", "gap"]
            .filter { id in context.facts.contains { $0.id == id } }
        let normalized = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [requested]), context: context, configuration: configuration)
        let article = try CommentaryValidationService.render(.init(selection: normalized, inputTokens: 0, outputTokens: 0), context: context, configuration: configuration)
        XCTAssertLessThanOrEqual(article.text.split(whereSeparator: \.isWhitespace).count, configuration.maxPreviewWords)
        XCTAssertLessThanOrEqual(article.factIDs.filter { $0.hasSuffix(".table") || $0 == "gap" }.count, 1)
        XCTAssertFalse(article.factIDs.contains("home.form") && article.factIDs.contains("home.streak"))
        XCTAssertTrue(context.facts.first { $0.id == "home.form" }?.text.contains("S–U–N") == true)
    }

    func testInsightfulPreviewMayExceed150WordsWithoutForcingShortSelectionsToExpand() throws {
        let original = try context()
        let extra = CommentaryFact(id: "home.insight", group: "home", text: Array(repeating: "Belegter Zusatzkontext", count: 80).joined(separator: " "), sourceIDs: [])
        let expanded = CommentaryContext(kind: original.kind, targetKey: original.targetKey, seasonID: original.seasonID,
            matchID: original.matchID, gameday: original.gameday, cutoff: original.cutoff, historical: original.historical,
            partial: original.partial, leagueCode: original.leagueCode, titles: original.titles,
            facts: original.facts + [extra], requiredFactIDs: original.requiredFactIDs, warnings: original.warnings)
        let selected = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [["fixture", "home.insight", "away.form"]]), context: expanded, configuration: settings())
        let longer = try CommentaryValidationService.render(.init(selection: selected, inputTokens: 0, outputTokens: 0), context: expanded, configuration: settings())
        XCTAssertGreaterThan(longer.text.split(whereSeparator: \.isWhitespace).count, 150)
        XCTAssertLessThanOrEqual(longer.text.split(whereSeparator: \.isWhitespace).count, 300)
        let brief = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [["fixture", "home.form", "away.form"]]), context: expanded, configuration: settings())
        XCTAssertFalse(brief.paragraphs.flatMap { $0 }.contains(extra.id))
        let shorter = try CommentaryValidationService.render(.init(selection: brief, inputTokens: 0, outputTokens: 0), context: expanded, configuration: settings())
        XCTAssertLessThan(shorter.text.split(whereSeparator: \.isWhitespace).count, 150)
    }

    func testSuspensionsCoverKickoffAndExplainRecentInvolvementWithoutInventingStarts() throws {
        let (base, target, now) = fixture()
        let player = Player(id: UUID(), sid: "blocked", image: nil, team_oeid: nil, email: nil, name: "Wichtiger Spieler", number: "9", birthday: "1990-01-01",
                            teamID: target.$homeTeam.id, nationality: "AT", position: "Sturm", eligibility: .Gesperrt,
                            registerDate: "", identification: nil, status: true, blockdate: target.details.date!.addingTimeInterval(1))
        let recent = base.matches[0]
        recent.homeBlanket?.players = [.init(id: player.id!, sid: "p", name: player.name, number: 9)]
        let goal = MatchEvent(id: UUID(), matchId: recent.id!, type: .goal, playerId: player.id!, minute: 10, name: player.name, image: nil, number: nil, assign: .home)
        recent.$events.value = [goal]
        func build() throws -> CommentaryContext {
            try CommentaryContextBuilder.preview(match: target, data: .init(season: base.season, league: base.league, teams: base.teams, matches: base.matches, players: [player]), meetings: [], now: now)
        }
        let blocked = try build()
        let absence = try XCTUnwrap(blocked.facts.first { $0.id == "home.suspended.summary" })
        XCTAssertTrue(absence.text.contains("Sperre reicht")); XCTAssertTrue(absence.text.contains("1 Treffer"))
        XCTAssertTrue(blocked.requiredFactIDs.contains(absence.id))
        XCTAssertFalse(blocked.facts.contains { $0.id == "home.scorer.\(player.id!)" })
        XCTAssertFalse(absence.text.contains("Stammspieler")); XCTAssertFalse(absence.text.contains("Startelf"))
        let normalized = CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: [["fixture", "home.form", "away.form"]]), context: blocked)
        XCTAssertTrue(normalized.paragraphs.flatMap { $0 }.contains(absence.id))
        recent.$events.value = []
        XCTAssertTrue(try build().facts.first { $0.id == absence.id }?.text.contains("Teamspielberichte") == true)
        for until in [target.details.date!, target.details.date!.addingTimeInterval(-1)] {
            player.blockdate = until
            XCTAssertFalse(try build().facts.contains { $0.id.contains("suspended") })
        }
        player.blockdate = nil
        XCTAssertFalse(try build().facts.contains { $0.id.contains("suspended") })
        player.blockdate = target.details.date!.addingTimeInterval(86400)
        player.eligibility = .Spielberechtigt
        XCTAssertFalse(try build().facts.contains { $0.id.contains("suspended") })
        player.eligibility = .Gesperrt; target.status = .done
        XCTAssertFalse(try build().facts.contains { $0.id.contains("suspended") })
    }

    private func trendHistory(_ target: Match, now: Date, scored: [Int], conceded: [Int]) -> [Match] {
        zip(scored, conceded).enumerated().map { index, scores in
            let reverse = index % 2 == 1
            let kickoff = now.addingTimeInterval(-Double(index + 1) * 86400)
            let match = Match(id: UUID(), details: .init(gameday: index + 1, date: kickoff, location: "Testplatz"),
                homeTeamId: reverse ? target.$awayTeam.id : target.$homeTeam.id,
                awayTeamId: reverse ? target.$homeTeam.id : target.$awayTeam.id,
                homeBlanket: nil, awayBlanket: nil,
                score: .init(home: reverse ? scores.1 : scores.0, away: reverse ? scores.0 : scores.1), status: .done,
                seasonId: target.$season.id, secondHalfEndDate: kickoff.addingTimeInterval(3600))
            match.$events.value = []
            return match
        }
    }

    func testDefensiveTrendUsesSeparateWindowsAndDoesNotMistakeWinningForGoodDefending() throws {
        let (_, target, now) = fixture()
        for (conceded, expected) in [([1, 1, 1, 4, 4, 4], "zeigt Besserung"),
                                    ([4, 4, 4, 1, 1, 1], "die andere Richtung"),
                                    ([3, 3, 3, 3, 4, 3], "keine klare Entspannung")] {
            let history = trendHistory(target, now: now, scored: [8, 8, 8, 8, 8, 8], conceded: conceded)
            let trend = try XCTUnwrap(CommentaryContextBuilder.defensiveTrend(teamID: target.$homeTeam.id, teamName: "Heim", matches: history, label: "home"))
            XCTAssertTrue(trend.text.contains(expected))
            XCTAssertEqual(trend.sourceIDs.count, 6)
            XCTAssertNil(CommentaryContextBuilder.defensiveTrend(teamID: target.$homeTeam.id, teamName: "Heim", matches: Array(history.prefix(5)), label: "home"))
            history[0].status = .cancelled
            XCTAssertNil(CommentaryContextBuilder.defensiveTrend(teamID: target.$homeTeam.id, teamName: "Heim", matches: history, label: "home"))
        }
    }

    func testGoalRichOutlookRequiresBothCurrentAttacksAndDefencesAndIgnoresOutliersAndAwards() throws {
        let (base, target, now) = fixture()
        let history = trendHistory(target, now: now, scored: [6, 6, 6, 6, 6, 6], conceded: [4, 4, 4, 4, 4, 4])
        let outlook = try XCTUnwrap(CommentaryContextBuilder.goalOutlook(homeID: target.$homeTeam.id, awayID: target.$awayTeam.id, matches: history))
        XCTAssertTrue(outlook.text.contains("erwarten")); XCTAssertFalse(outlook.text.contains("garantiert"))
        XCTAssertTrue(CommentaryContextBuilder.goalOutlook(homeID: target.$homeTeam.id, awayID: target.$awayTeam.id, matches: history, historical: true)?.text.contains("damaliger Sicht") == true)
        let data = CommentarySeasonData(season: base.season, league: base.league, teams: base.teams, matches: history + [target], players: [])
        let context = try CommentaryContextBuilder.preview(match: target, data: data, meetings: [], now: now)
        XCTAssertTrue(context.requiredFactIDs.contains("goal_outlook"))
        XCTAssertTrue(context.requiredFactIDs.contains("home.defence_trend"))
        XCTAssertTrue(context.requiredFactIDs.contains("away.defence_trend"))
        XCTAssertFalse(context.facts.first { $0.id == "home.form" }?.text.contains("Gegentore") == true)
        XCTAssertFalse(context.facts.contains { $0.id == "home.defence" })
        XCTAssertFalse(outlook.sourceIDs.contains(target.id!.uuidString))
        for goals in [[0, 1, 0, 9, 9, 9], [12, 0, 0, 9, 9, 9]] {
            let improved = trendHistory(target, now: now, scored: [6, 6, 6, 6, 6, 6], conceded: goals)
            XCTAssertNil(CommentaryContextBuilder.goalOutlook(homeID: target.$homeTeam.id, awayID: target.$awayTeam.id, matches: improved))
        }
        XCTAssertNil(CommentaryContextBuilder.goalOutlook(homeID: target.$homeTeam.id, awayID: target.$awayTeam.id, matches: Array(history.prefix(2))))
        let awarded = trendHistory(target, now: now, scored: [900, 1, 1, 1], conceded: [900, 1, 1, 1])
        awarded[0].status = .cancelled
        XCTAssertNil(CommentaryContextBuilder.goalOutlook(homeID: target.$homeTeam.id, awayID: target.$awayTeam.id, matches: awarded))
    }

    func testSeasonNewsOverviewScopesBySeasonAndRoundAndReadsActualNewsEdits() async throws {
        try await withMongo { app, store in
            let (data, _, now) = self.fixture()
            try await data.league.create(on: app.db)
            try await data.season.create(on: app.db)
            for match in data.matches { try await match.create(on: app.db) }
            try await CommentarySeasonIndexesMigration().prepare(on: app.db)
            let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
            let runtime = CommentaryRuntime(configuration: self.settings(), store: store, contexts: CommentaryStubContext(context: context), inference: CommentaryMockInference())
            app.commentary = runtime; try app.register(collection: CommentatorController())
            let job = try await runtime.jobs.enqueue(context: context, options: .init())
            try await runtime.jobs.process(job.id, slot: 0)
            let article = try await store.article(job.articleID)
            let weeklyID = try XCTUnwrap(article?.publishedNewsID)
            let weekly = try await NewsItem.find(weeklyID, on: app.db)
            weekly?.title = "Redaktionell geändert"; try await weekly?.save(on: app.db)
            let linked = NewsItem(id: UUID(), text: "<p>Ein Spielbericht.</p>", title: "Zum ersten Spiel", tag: "TEST")
            linked.matchID = data.matches[0].id!.uuidString.lowercased(); try await linked.create(on: app.db)
            let unrelated = NewsItem(id: UUID(), text: "Andere Saison", title: "Nicht zuordnen", tag: "TEST")
            unrelated.matchID = UUID().uuidString; try await unrelated.create(on: app.db)
            // A newer dry run must not hide the real completed/published job.
            _ = try await runtime.jobs.enqueue(context: context, options: .init(dryRun: true, idempotencyKey: "later-test"), now: Date().addingTimeInterval(60))
            let overview = try await CommentarySeasonOverview.fetch(data.season.id!, on: app.db)
            let round = try XCTUnwrap(overview.rounds.first { $0.gameday == 2 })
            XCTAssertEqual(round.job?.id, job.id); XCTAssertEqual(round.job?.state, .completed)
            XCTAssertEqual(round.weeklyNewsID, weeklyID)
            XCTAssertEqual(round.news.first?.title, "Redaktionell geändert")
            XCTAssertEqual(overview.rounds.first { $0.gameday == 1 }?.news.first?.id, linked.id)
            XCTAssertFalse(overview.rounds.flatMap(\.news).contains { $0.id == unrelated.id })
            try app.test(.GET, "commenter/v1/seasons/\(data.season.id!)/news", beforeRequest: {
                $0.headers.add(name: "X-Commentator-Key", value: self.settings().serviceKey)
            }) { XCTAssertEqual($0.status, .ok) }
            try await weekly?.delete(on: app.db)
            let afterDelete = try await CommentarySeasonOverview.fetch(data.season.id!, on: app.db)
            let saved = try XCTUnwrap(afterDelete.rounds.first { $0.gameday == 2 })
            XCTAssertNil(saved.weeklyNewsID); XCTAssertNotNil(saved.articleID)
        }
    }

    func testAnonymousPreviewFeedbackIsIdempotentChangeableAndRemovable() async throws {
        try await withMongo { app, store in
            let context = try self.context(), settings = self.settings()
            let runtime = CommentaryRuntime(configuration: settings, store: store, contexts: CommentaryStubContext(context: context), inference: CommentaryMockInference())
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            try await PreviewFeedbackIndexesMigration().prepare(on: app.db)
            let job = try await runtime.jobs.enqueue(context: context, options: .init())
            try await runtime.jobs.process(job.id, slot: 0)
            let path = "webClient/match/\(context.matchID!)/preview"
            var version: String?
            try app.test(.GET, path) { response in
                version = try response.content.decode(GeneratedCommentary.self).feedbackVersion
                XCTAssertEqual(version?.count, 64)
            }
            let id = try XCTUnwrap(version), visitor = UUID()
            for (vote, likes, dislikes) in [(PreviewFeedbackVote?.some(.like), 1, 0), (.some(.like), 1, 0), (.some(.dislike), 0, 1), (nil, 0, 0)] {
                try app.test(.POST, path + "/feedback", beforeRequest: {
                    try $0.content.encode(PreviewFeedbackRequest(visitorId: visitor, previewVersion: id, vote: vote))
                }) {
                    XCTAssertEqual($0.status, .ok)
                    let summary = try $0.content.decode(PreviewFeedbackSummary.self)
                    XCTAssertEqual(summary.likes, likes); XCTAssertEqual(summary.dislikes, dislikes)
                    XCTAssertEqual(summary.vote, vote)
                }
            }
            let feedback = PreviewFeedbackService(database: app.db)
            _ = try await feedback.submit(matchID: context.matchID!, request: .init(visitorId: visitor, previewVersion: id, vote: .like))
            _ = try await feedback.submit(matchID: context.matchID!, request: .init(visitorId: UUID(), previewVersion: id, vote: .dislike))
            try app.test(.GET, path + "/feedback?preview_version=\(id)") {
                let counts = try $0.content.decode(PreviewFeedbackSummary.self)
                XCTAssertEqual(counts.likes, 1); XCTAssertEqual(counts.dislikes, 1)
            }
            let count = try await store.collection(PreviewFeedbackService.votes).count().get()
            XCTAssertEqual(count, 2)
            let documents = try await store.collection(PreviewFeedbackService.votes).find().allResults().get()
            for document in documents {
                XCTAssertNil(document["visitorId"]); XCTAssertNil(document["visitorID"])
                XCTAssertNil(document["ip"]); XCTAssertNil(document["userID"])
                XCTAssertFalse(String(describing: document).contains(visitor.uuidString))
            }
            try app.test(.GET, "commenter/v1/generate/match/\(context.matchID!)/feedback") { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testFeedbackStaysWithPublicSnapshotAndArchivesExactTextAcrossRevisions() async throws {
        try await withMongo { app, store in
            let context = try self.context(), settings = self.settings()
            let runtime = CommentaryRuntime(configuration: settings, store: store, contexts: CommentaryStubContext(context: context), inference: CommentaryMockInference())
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            let job = try await runtime.jobs.enqueue(context: context, options: .init())
            try await runtime.jobs.process(job.id, slot: 0)
            let stored = try await store.article(job.articleID)
            var article = try XCTUnwrap(stored)
            let old = article.content
            let version = PreviewFeedbackService.version(articleID: article.id, content: old)
            let service = PreviewFeedbackService(database: app.db), visitor = UUID()
            _ = try await service.submit(matchID: context.matchID!, request: .init(visitorId: visitor, previewVersion: version, vote: .like))
            article.content = .init(title: "Redaktionell überarbeitet", text: "Ein anderer Text.", html: "<p>Ein anderer Text.</p>", language: old.language,
                generatedAt: old.generatedAt, provider: old.provider, model: old.model, promptVersion: old.promptVersion,
                contextHash: old.contextHash, factIDs: [], inputTokens: old.inputTokens, outputTokens: old.outputTokens, status: .draft)
            article.revision += 1
            try await store.saveArticle(article, expectedRevision: article.revision - 1)
            let stillPublic = try await service.summary(matchID: context.matchID!, expectedVersion: version)
            XCTAssertEqual(stillPublic.likes, 1) // A draft edit cannot move the public votes.
            let replacement = try await runtime.jobs.publish(article: article, overwrite: false)
            let next = PreviewFeedbackService.version(articleID: replacement.id, content: replacement.content)
            XCTAssertNotEqual(version, next)
            let counts = try await service.summary(matchID: context.matchID!, expectedVersion: next)
            XCTAssertEqual(counts.likes, 0)
            try app.test(.POST, "webClient/match/\(context.matchID!)/preview/feedback", beforeRequest: {
                try $0.content.encode(PreviewFeedbackRequest(visitorId: visitor, previewVersion: version, vote: .dislike))
            }) { XCTAssertEqual($0.status, .conflict) }
            _ = try await service.submit(matchID: context.matchID!, request: .init(visitorId: visitor, previewVersion: next, vote: .dislike))
            try app.test(.GET, "commenter/v1/generate/match/\(context.matchID!)/feedback", beforeRequest: {
                $0.headers.add(name: "X-Commentator-Key", value: settings.serviceKey)
            }) {
                XCTAssertEqual($0.status, .ok)
                let report = try $0.content.decode(PreviewFeedbackReport.self)
                XCTAssertEqual(report.versions.count, 2)
                XCTAssertEqual(report.versions.first { $0.current }?.content.text, "Ein anderer Text.")
                XCTAssertEqual(report.versions.first { !$0.current }?.content.text, old.text)
                XCTAssertEqual(report.versions.first { !$0.current }?.likes, 1)
            }
        }
    }

    func testFeedbackRejectsMissingAndUnpublishedPreviewsAndInvalidInput() async throws {
        try await withMongo { app, store in
            let context = try self.context()
            let runtime = CommentaryRuntime(configuration: self.settings(), store: store, contexts: CommentaryStubContext(context: context), inference: CommentaryMockInference())
            app.commentary = runtime
            try app.register(collection: CommentatorController())
            let path = "webClient/match/\(context.matchID!)/preview/feedback"
            try app.test(.GET, path) { XCTAssertEqual($0.status, .notFound) }
            let job = try await runtime.jobs.enqueue(context: context, options: .init(publish: false))
            try await runtime.jobs.process(job.id, slot: 0)
            try app.test(.POST, path, beforeRequest: {
                try $0.content.encode(PreviewFeedbackRequest(visitorId: UUID(), previewVersion: "unknown", vote: .like))
            }) { XCTAssertEqual($0.status, .notFound) }
            try app.test(.POST, path, beforeRequest: {
                $0.headers.contentType = .json
                $0.body = ByteBuffer(string: "{\"visitorId\":\"not-a-uuid\",\"previewVersion\":\"x\",\"vote\":\"like\"}")
            }) { XCTAssertEqual($0.status, .badRequest) }
            let count = try await store.collection(PreviewFeedbackService.votes).count().get()
            XCTAssertEqual(count, 0)
        }
    }

    func testNewNewsUsesDefaultImageAndKeepsExplicitAlternative() {
        XCTAssertEqual(NewsItem(title: "Neue News").image, NewsItem.defaultImageURL)
        XCTAssertEqual(NewsItem(image: "  ", title: "Neue News").image, NewsItem.defaultImageURL)
        XCTAssertEqual(NewsItem(image: "https://www.oekfb.eu/alternative.jpg").image, "https://www.oekfb.eu/alternative.jpg")
    }

    func testWeeklyReviewCoversEveryMatchWithSafeHeadingsAndStaysWithinItsSeason() throws {
        let (data, _, now) = fixture()
        let (other, _, _) = fixture()
        other.matches[1].score = .init(home: 999, away: 998)
        let mixed = CommentarySeasonData(season: data.season, league: data.league, teams: data.teams, matches: data.matches + other.matches, players: [])
        let context = try CommentaryContextBuilder.summary(data: mixed, gameday: 2, allowPartial: false, now: now)
        let results = data.matches.filter { $0.details.gameday == 2 }
        XCTAssertEqual(context.facts.filter { $0.id.hasPrefix("result.") }.count, results.count)
        XCTAssertFalse(context.facts.map(\.text).joined().contains("999"))
        let minimal = CommentarySelection(titleIndex: 0, language: "de", paragraphs: [["round"]])
        let selected = CommentaryValidationService.normalize(minimal, context: context, configuration: settings())
        let article = try CommentaryValidationService.render(.init(selection: selected, inputTokens: 0, outputTokens: 0), context: context, configuration: settings())
        for match in results { XCTAssertTrue(article.factIDs.contains("result.\(match.id!)")) }
        XCTAssertEqual(article.html.components(separatedBy: "<h2>").count - 1, results.count + 1) // Each game + table.
        XCTAssertEqual(article.promptVersion, "league-review-de-v2")
        XCTAssertFalse(CommentaryPromptBuilder.instructions(for: context, configuration: settings()).contains("Drei kurze Absätze"))
        XCTAssertTrue(article.text.contains("So steht die Liga"))
        data.teams[0].teamName = "<script>Heim</script>"
        let escapedContext = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
        let escapedSelection = CommentaryValidationService.normalize(minimal, context: escapedContext, configuration: settings())
        let escaped = try CommentaryValidationService.render(.init(selection: escapedSelection, inputTokens: 0, outputTokens: 0), context: escapedContext, configuration: settings())
        XCTAssertTrue(escaped.html.contains("&lt;script&gt;")); XCTAssertFalse(escaped.html.contains("<script>"))
    }

    func testWeeklyReviewHighlightsRecordedCardsAndMultipleGoalsWithoutInventingFlow() throws {
        let (data, _, now) = fixture()
        let match = data.matches[2], player = UUID()
        var events = [MatchEvent]()
        for minute in [2, 15, 20] { events.append(.init(id: UUID(), matchId: match.id!, type: .goal, playerId: player, minute: minute, name: "Dreifachtorschütze", image: nil, number: nil, assign: .home)) }
        events.append(.init(id: UUID(), matchId: match.id!, type: .yellowCard, playerId: player, minute: 21, name: "Dreifachtorschütze", image: nil, number: nil, assign: .home))
        events.append(.init(id: UUID(), matchId: match.id!, type: .redCard, playerId: player, minute: 30, name: "Dreifachtorschütze", image: nil, number: nil, assign: .home))
        match.$events.value = events + [events.last!]
        let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
        let text = context.facts.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("mindestens 3 Treffer"))
        XCTAssertTrue(text.contains("1 Gelbe Karte"))
        XCTAssertEqual(context.facts.filter { $0.id.hasPrefix("card.") }.count, 1)
        XCTAssertTrue(text.contains("Rote Karte in Minute 30"))
        XCTAssertFalse(text.contains("Führungswechsel")); XCTAssertFalse(context.facts.contains { $0.id.hasPrefix("race.") })
    }

    func testPreviewTableStakesAreConditionalAndDoNotInventRelegationRules() throws {
        let (data, match, now) = fixture()
        func row(_ rank: Int, _ points: Int, id: UUID = UUID()) -> TableItem {
            .init(shortName: nil, image: "", name: "Team \(rank)", points: points, id: id, goals: 0, ranking: rank,
                  wins: 0, draws: 0, losses: 0, scored: 0, against: 0, difference: 0, form: [])
        }
        let rows = [row(1, 20), row(2, 16), row(3, 12), row(4, 10, id: match.$homeTeam.id), row(5, 9, id: match.$awayTeam.id), row(6, 5), row(7, 4), row(8, 2)]
        let facts = CommentaryContextBuilder.tableStakes(match: match, table: rows, fixtures: [match], previous: [data.matches[0]], now: now)
        let home = try XCTUnwrap(facts.first { $0.id == "home.stakes" })
        XCTAssertTrue(home.text.contains("Top 3")); XCTAssertTrue(home.text.contains("13 Punkten"))
        XCTAssertTrue(home.text.contains("könnte")); XCTAssertTrue(home.text.contains("Andere Ergebnisse und die Tordifferenz"))
        XCTAssertFalse(home.text.contains("Abstieg")); XCTAssertFalse(home.text.contains("nächsten Saison"))
        let lower = [row(1, 30), row(2, 25), row(3, 20), row(4, 15), row(5, 10), row(6, 5, id: match.$homeTeam.id), row(7, 4, id: match.$awayTeam.id), row(8, 2)]
        let lowerFacts = CommentaryContextBuilder.tableStakes(match: match, table: lower, fixtures: [match], previous: [data.matches[0]], now: now)
        XCTAssertTrue(lowerFacts.first { $0.id == "home.stakes" }?.text.contains("unteren Tabellenbereich") == true)
    }

    func testWeeklyScorerMovementUsesCompleteBeforeAfterTablesAndDistinguishesSharedLead() throws {
        let (data, _, now) = fixture()
        let leader = UUID(), chaser = UUID(), first = data.matches[0], second = data.matches[1]
        for match in data.matches { match.$events.value = []; match.score = .init(home: 0, away: 0) }
        func goals(_ match: Match, id: UUID, name: String, count: Int, side: MatchAssignment) -> [MatchEvent] {
            (1...count).map { minute in .init(id: UUID(), matchId: match.id!, type: .goal, playerId: id, minute: minute, name: name, image: nil, number: nil, assign: side) }
        }
        first.score = .init(home: 2, away: 1)
        first.$events.value = goals(first, id: leader, name: "Bisher Erster", count: 2, side: .home) + goals(first, id: chaser, name: "Verfolger", count: 1, side: .away)
        for count in [3, 1] {
            second.score = .init(home: count, away: 0)
            second.$events.value = goals(second, id: chaser, name: "Verfolger", count: count, side: .home)
            let context = try CommentaryContextBuilder.summary(data: data, gameday: 2, allowPartial: false, now: now)
            let movement = try XCTUnwrap(context.facts.first { $0.id == "race.\(chaser)" })
            XCTAssertTrue(movement.text.contains("\(count + 1) Saisontoren"))
            XCTAssertTrue(movement.text.contains("von Rang 2"))
            XCTAssertTrue(movement.text.contains(count == 1 ? "geteilten Spitzenplatz" : "den Spitzenplatz"))
        }
    }

    private func withMongo(_ run: (Application, MongoCommentaryStore) async throws -> Void) async throws {
        guard let port = Environment.get("COMMENTATOR_TEST_MONGO_PORT"), Int(port) != nil else {
            throw XCTSkip("Set COMMENTATOR_TEST_MONGO_PORT to an isolated loopback MongoDB.")
        }
        let app = Application(.testing); app.logger.logLevel = .critical
        let name = "oekfb_commentary_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(name)"), as: .mongo)
        let store = MongoCommentaryStore(database: app.db)
        defer { try? (app.db as? MongoDatabaseRepresentable)?.raw.drop().wait(); app.shutdown() }
        try await CommentaryIndexesMigration().prepare(on: app.db)
        try await run(app, store)
    }
}

private actor CommentaryMockInference: AIInferenceService {
    var calls = 0
    var failures: [CommentaryInferenceError]
    let invalid: Bool
    init(failures: [CommentaryInferenceError] = [], invalid: Bool = false) { self.failures = failures; self.invalid = invalid }
    static func selection(_ context: CommentaryContext) -> CommentarySelection {
        var selected = context.requiredFactIDs
        var words = context.facts.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        for group in ["home", "away"] {
            if let fact = context.facts.first(where: { $0.group == group }), !selected.contains(fact.id) {
                selected.append(fact.id); words += fact.text.split(separator: " ").count
            }
        }
        for fact in context.facts where !selected.contains(fact.id) {
            let count = fact.text.split(separator: " ").count
            if words + count <= 225 { selected.append(fact.id); words += count }
        }
        var paragraphs = [[String]]()
        for start in stride(from: 0, to: selected.count, by: 4) { paragraphs.append(Array(selected[start..<min(start + 4, selected.count)])) }
        return CommentaryValidationService.normalize(.init(titleIndex: 0, language: "de", paragraphs: paragraphs), context: context)
    }
    func generate(context: CommentaryContext, configuration: CommentaryConfiguration) async throws -> CommentaryInferenceResult {
        calls += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        let selection = invalid ? CommentarySelection(titleIndex: 0, language: "de", paragraphs: [["fixture", "invented"]]) : Self.selection(context)
        return .init(selection: selection, inputTokens: 50, outputTokens: 50)
    }
}

private struct CommentaryStubContext: CommentaryContextProviding {
    let context: CommentaryContext
    func matchPreview(_ id: UUID, now: Date) async throws -> CommentaryContext { context }
    func gameDaySummary(_ seasonID: UUID, gameday: Int, allowPartial: Bool, now: Date) async throws -> CommentaryContext { context }
}

private struct CommentaryTestResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response { .init(status: .ok) }
}

private struct UnavailableCommentaryStore: CommentaryStore {
    private func unavailable<T>() throws -> T { throw Abort(.serviceUnavailable) }
    func insertJob(_ job: CommentaryJob) async throws -> CommentaryJob { try unavailable() }
    func job(_ id: String) async throws -> CommentaryJob? { try unavailable() }
    func latest(targetKey: String) async throws -> CommentaryJob? { try unavailable() }
    func pending(now: Date, limit: Int) async throws -> [CommentaryJob] { try unavailable() }
    func claim(_ id: String, owner: String, now: Date, lease: Int, maxAttempts: Int) async throws -> CommentaryJob? { try unavailable() }
    func renew(_ id: String, owner: String, until: Date) async throws { throw Abort(.serviceUnavailable) }
    func finish(_ job: CommentaryJob, owner: String) async throws { throw Abort(.serviceUnavailable) }
    func article(_ id: String) async throws -> CommentaryArticle? { try unavailable() }
    func saveArticle(_ article: CommentaryArticle, expectedRevision: Int) async throws { throw Abort(.serviceUnavailable) }
    func publish(_ article: CommentaryArticle, overwrite: Bool, now: Date) async throws -> CommentaryArticle { try unavailable() }
    func acquireSlot(_ id: String, owner: String, now: Date, lease: Int) async throws -> Bool { try unavailable() }
    func releaseSlot(_ id: String, owner: String) async throws { throw Abort(.serviceUnavailable) }
}

private final class CommentaryMockClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    let context: CommentaryContext
    let status: HTTPStatus
    let truncated: Bool
    let transportFailure: Bool
    private let lock = NSLock()
    private var captured: ClientRequest?
    var request: ClientRequest? { lock.lock(); defer { lock.unlock() }; return captured }
    init(eventLoop: EventLoop, context: CommentaryContext, status: HTTPStatus = .ok, truncated: Bool = false, transportFailure: Bool = false) {
        self.eventLoop = eventLoop; self.context = context; self.status = status; self.truncated = truncated; self.transportFailure = transportFailure
    }
    func delegating(to eventLoop: EventLoop) -> Client { self }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        lock.lock(); captured = request; lock.unlock()
        if transportFailure { return eventLoop.makeFailedFuture(Abort(.gatewayTimeout)) }
        let selection = try! JSONEncoder().encode(CommentaryMockInference.selection(context))
        let response: [String: Any] = ["status": truncated ? "incomplete" : "completed", "output": [["type": "message", "content": [["type": "output_text", "text": String(decoding: selection, as: UTF8.self)]]]], "usage": ["input_tokens": 25, "output_tokens": 30]]
        let data = try! JSONSerialization.data(withJSONObject: response)
        return eventLoop.makeSucceededFuture(.init(status: status, headers: ["Retry-After": "1"], body: ByteBuffer(data: data)))
    }
}
