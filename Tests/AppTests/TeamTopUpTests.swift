@testable import App
import Crypto
import Fluent
import FluentMongoDriver
import MongoKitten
import XCTVapor

final class TeamTopUpTests: XCTestCase {
    private func config(overrides: [String: String] = [:]) throws -> TeamStripeConfiguration {
        let values = ["STRIPE_SANDBOX_SECRET_KEY": "sk_test_fixture", "STRIPE_SANDBOX_PUBLISHABLE_KEY": "pk_test_fixture",
            "STRIPE_SANDBOX_WEBHOOK_SECRET": "whsec_fixture", "STRIPE_CHECKOUT_SUCCESS_URL": "https://app.example.com/finance/success",
            "STRIPE_CHECKOUT_CANCEL_URL": "https://app.example.com/finance/cancel"].merging(overrides) { _, new in new }
        return try TeamStripeConfiguration { values[$0] }
    }

    private func record(teamID: UUID = UUID(), userID: UUID = UUID(), amount: Int = 10000, key: String = UUID().uuidString) -> TeamTopUp {
        TeamTopUp(teamID: teamID, userID: userID, teamName: "Test Team", recipient: "test@example.com",
            input: TeamTopUpInput(amountMinor: amount, idempotencyKey: key), livemode: false)
    }

    private func intentData(_ topUp: TeamTopUp, status: String = "succeeded", amount: Int? = nil, failed: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "pi_\(topUp.id)", "amount": amount ?? topUp.amountMinor,
            "amount_received": status == "succeeded" ? topUp.amountMinor : 0,
            "currency": "eur", "livemode": false, "status": status, "client_secret": "pi_fixture_secret_private",
            "metadata": ["kind": "oekfb_team_top_up", "top_up_id": topUp.id, "team_id": topUp.teamID.uuidString],
            "latest_charge": ["id": "ch_fixture", "created": 1789480800],
            "last_payment_error": failed ? ["code": "card_declined"] : NSNull()])
    }

    private func checkoutRecord(teamID: UUID = UUID(), userID: UUID = UUID(), key: String = UUID().uuidString) throws -> TeamTopUp {
        var topUp = record(teamID: teamID, userID: userID, key: key)
        topUp.paymentFlow = .checkout
        let urls = try config().checkoutReturnURLs(topUpID: topUp.id)
        topUp.checkoutSuccessURL = urls.success; topUp.checkoutCancelURL = urls.cancel
        return topUp
    }

    private func checkoutData(_ topUp: TeamTopUp, status: String = "open", paymentStatus: String = "unpaid",
                              hasIntent: Bool = false, amount: Int? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "cs_test_\(topUp.id)", "mode": "payment",
            "amount_total": amount ?? topUp.amountMinor, "currency": "eur", "livemode": false,
            "client_reference_id": topUp.id, "metadata": ["kind": "oekfb_team_top_up", "top_up_id": topUp.id, "team_id": topUp.teamID.uuidString],
            "status": status, "payment_status": paymentStatus,
            "payment_intent": hasIntent ? "pi_\(topUp.id)" : NSNull(),
            "url": status == "open" ? "https://checkout.stripe.com/c/pay/cs_test_\(topUp.id)" : NSNull(),
            "expires_at": topUp.createdAt.addingTimeInterval(24 * 3600).timeIntervalSince1970])
    }

    private func sendEvent(_ manager: TeamTopUpManager, topUp: TeamTopUp, type: String, eventID: String) async throws {
        let objectID = type.hasPrefix("checkout.") ? "cs_test_\(topUp.id)" : "pi_\(topUp.id)"
        let body = try JSONSerialization.data(withJSONObject: ["id": eventID, "type": type, "livemode": false,
            "data": ["object": ["id": objectID, "metadata": ["kind": "oekfb_team_top_up", "top_up_id": topUp.id]]]])
        try await manager.receiveWebhook(body: body, signature: signature(body, timestamp: Int(Date().timeIntervalSince1970)))
    }

    private func signature(_ body: Data, timestamp: Int) -> String {
        var signed = Data("\(timestamp).".utf8); signed.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data("whsec_fixture".utf8)))
        return "t=\(timestamp),v1=\(mac.map { String(format: "%02x", $0) }.joined())"
    }

    func testSignatureRejectsTamperingStaleAndMalformedHeaders() throws {
        let body = Data(#"{"id":"evt_fixture"}"#.utf8)
        let time = 1789480800
        let header = signature(body, timestamp: time)
        XCTAssertNoThrow(try TeamStripeClient.verifySignature(body: body, header: header,
            secret: "whsec_fixture", now: Date(timeIntervalSince1970: Double(time))))
        XCTAssertThrowsError(try TeamStripeClient.verifySignature(body: body + Data(" ".utf8), header: header,
            secret: "whsec_fixture", now: Date(timeIntervalSince1970: Double(time))))
        XCTAssertThrowsError(try TeamStripeClient.verifySignature(body: body, header: header,
            secret: "whsec_fixture", now: Date(timeIntervalSince1970: Double(time + 301))))
        XCTAssertThrowsError(try TeamStripeClient.verifySignature(body: body, header: "t=invalid,v1=bad", secret: "whsec_fixture"))
    }

    func testInputValidationIdempotencyAndMixedKeys() throws {
        for amount in [-100, 0, 49, 500001] {
            XCTAssertThrowsError(try TeamTopUpInput(amountMinor: amount, idempotencyKey: "key").validate(maximum: 500000))
        }
        XCTAssertNoThrow(try TeamTopUpInput(amountMinor: 50, idempotencyKey: UUID().uuidString).validate(maximum: 500000))
        XCTAssertThrowsError(try TeamTopUpInput(amountMinor: 100, idempotencyKey: "bad\nkey").validate(maximum: 500000))
        let team = UUID(), user = UUID()
        let a = record(teamID: team, userID: user, key: "same")
        XCTAssertEqual(a.id, record(teamID: team, userID: user, key: "same").id)
        XCTAssertNotEqual(a.id, record(teamID: UUID(), userID: user, key: "same").id)
        XCTAssertThrowsError(try TeamStripeConfiguration { ["STRIPE_SANDBOX_SECRET_KEY": "sk_test_a", "STRIPE_SANDBOX_PUBLISHABLE_KEY": "pk_live_b", "STRIPE_SANDBOX_WEBHOOK_SECRET": "whsec_a"][$0] })
    }

    func testStripeAmountAndMetadataMustMatchLocalRecord() throws {
        let topUp = record()
        let intent = try JSONDecoder().decode(TeamStripeIntent.self, from: intentData(topUp))
        XCTAssertNoThrow(try intent.validate(for: topUp))
        XCTAssertThrowsError(try intent.validate(for: record()))
        let wrongAmount = try JSONDecoder().decode(TeamStripeIntent.self, from: intentData(topUp, amount: 5000))
        XCTAssertThrowsError(try wrongAmount.validate(for: topUp))
    }

    func testNewEndpointsRequireAuthenticationAndEnforceOwnership() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try app.register(collection: TeamPaymentController())
        for (method, path) in [(HTTPMethod.GET, "payments/config"), (.POST, "payments/teams/\(UUID())/top-ups"),
                               (.POST, "payments/teams/\(UUID())/top-ups/checkout"), (.GET, "payments/top-ups/example/confirmation"),
                               (.GET, "payments/top-ups/example"), (.GET, "payments/teams/\(UUID())/invoices")] {
            try app.test(method, path) { XCTAssertEqual($0.status, .unauthorized) }
        }
        let user = User(id: UUID(), userID: "test", type: .team, firstName: "Test", lastName: "Owner", email: "test@example.com", passwordHash: "hash")
        let team = Team(); team.$user.id = user.id
        XCTAssertNoThrow(try TeamPaymentController.authorize(team: team, user: user))
        team.$user.id = UUID()
        XCTAssertThrowsError(try TeamPaymentController.authorize(team: team, user: user))
    }

    func testCheckoutConfigurationValidationAndLegacyRecordCompatibility() throws {
        let missing = try TeamStripeConfiguration { ["STRIPE_SANDBOX_SECRET_KEY": "sk_test_fixture", "STRIPE_SANDBOX_PUBLISHABLE_KEY": "pk_test_fixture",
            "STRIPE_SANDBOX_WEBHOOK_SECRET": "whsec_fixture"][$0] }
        XCTAssertEqual(try missing.checkoutReturnURLs(topUpID: "test").success, "https://api.oekfb.eu/payments/checkout/return?top_up_id=test")
        let config = try config(overrides: ["STRIPE_CHECKOUT_SUCCESS_URL": "http://localhost:3000/success?top_up_id=wrong&tab=finance"])
        let urls = try config.checkoutReturnURLs(topUpID: "actual")
        let query = try XCTUnwrap(URLComponents(string: urls.success)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "top_up_id" }.map(\.value), ["actual"])
        XCTAssertTrue(query.contains { $0.name == "tab" && $0.value == "finance" })
        for unsafe in ["http://app.example.com/return", "javascript:alert(1)", "https://user:password@app.example.com/return"] {
            XCTAssertThrowsError(try self.config(overrides: ["STRIPE_CHECKOUT_SUCCESS_URL": unsafe]).checkoutReturnURLs(topUpID: "test"))
        }
        XCTAssertNoThrow(try self.config(overrides: ["STRIPE_CHECKOUT_SUCCESS_URL": "", "STRIPE_CHECKOUT_CANCEL_URL": " "]).checkoutReturnURLs(topUpID: "test"))
        let original = record()
        let decoded = try BSONDecoder().decode(TeamTopUp.self, from: BSONEncoder().encode(original))
        XCTAssertNil(decoded.paymentFlow); XCTAssertEqual(decoded.flow, .sdk)
    }

    func testStripeModeSelectsOnlyMatchingCredentialsAndFailsClosed() throws {
        var values = ["STRIPE_SANDBOX_SECRET_KEY": "sk_test_fixture", "STRIPE_SANDBOX_PUBLISHABLE_KEY": "pk_test_fixture",
            "STRIPE_SANDBOX_WEBHOOK_SECRET": "whsec_sandbox", "STRIPE_PRODUCTION_SECRET_KEY": "sk_live_fixture",
            "STRIPE_PRODUCTION_PUBLISHABLE_KEY": "pk_live_fixture", "STRIPE_PRODUCTION_WEBHOOK_SECRET": "whsec_production"]
        let sandbox = try TeamStripeConfiguration { values[$0] }
        XCTAssertEqual(sandbox.mode, "sandbox"); XCTAssertFalse(sandbox.livemode)
        XCTAssertEqual(sandbox.webhookSecret, "whsec_sandbox")
        values["STRIPE_MODE"] = "production"
        let production = try TeamStripeConfiguration { values[$0] }
        XCTAssertTrue(production.livemode); XCTAssertEqual(production.secretKey, "sk_live_fixture")
        XCTAssertEqual(production.publishableKey, "pk_live_fixture")
        XCTAssertEqual(production.webhookSecret, "whsec_production")
        values["STRIPE_PRODUCTION_SECRET_KEY"] = ""
        XCTAssertThrowsError(try TeamStripeConfiguration { values[$0] }) // Never fall back to sandbox.
        values["STRIPE_PRODUCTION_SECRET_KEY"] = "sk_test_wrong"
        XCTAssertThrowsError(try TeamStripeConfiguration { values[$0] })
        values["STRIPE_MODE"] = "prod"
        XCTAssertThrowsError(try TeamStripeConfiguration { values[$0] })
        values["STRIPE_MODE"] = "sandbox"
        values["STRIPE_SANDBOX_SECRET_KEY"] = "sk_live_wrong"
        XCTAssertThrowsError(try TeamStripeConfiguration { values[$0] })
    }

    func testCheckoutSessionMustMatchTeamAmountAndFlow() throws {
        let topUp = try checkoutRecord()
        let session = try JSONDecoder().decode(TeamStripeCheckoutSession.self, from: checkoutData(topUp))
        XCTAssertNoThrow(try session.validate(for: topUp))
        var wrongFlow = topUp; wrongFlow.paymentFlow = nil
        XCTAssertThrowsError(try session.validate(for: wrongFlow))
        var wrongBinding = topUp; wrongBinding.checkoutSessionID = "cs_test_other"
        XCTAssertThrowsError(try session.validate(for: wrongBinding))
        XCTAssertThrowsError(try session.validate(for: checkoutRecord()))
        let wrongAmount = try JSONDecoder().decode(TeamStripeCheckoutSession.self, from: checkoutData(topUp, amount: 1))
        XCTAssertThrowsError(try wrongAmount.validate(for: topUp))
    }

    func testConfirmationDistinguishesPendingFailureAndCredited() throws {
        var topUp = try checkoutRecord()
        topUp.stripeStatus = "open"; topUp.checkoutStatus = "open"
        topUp.checkoutURL = "https://checkout.stripe.com/c/pay/cs_test_fixture"
        topUp.clientSecret = "must_never_be_exposed_for_checkout"
        XCTAssertEqual(topUp.confirmationHTTPStatus, .accepted)
        XCTAssertNil(TeamTopUpResponse(topUp, publishableKey: "pk_test_fixture").clientSecret)
        topUp.stripeStatus = "requires_payment_method"
        XCTAssertEqual(topUp.confirmationHTTPStatus, .accepted) // First card entry is not a failure.
        topUp.paymentFailed = true
        XCTAssertEqual(topUp.confirmationHTTPStatus, .paymentRequired)
        topUp.checkoutStatus = "expired"
        XCTAssertEqual(topUp.confirmationHTTPStatus, .gone)
        XCTAssertNil(TeamTopUpResponse(topUp, publishableKey: "pk_test_fixture").checkoutUrl)
        topUp.needsReview = true
        XCTAssertEqual(topUp.confirmationHTTPStatus, .conflict)
        topUp.needsReview = false; topUp.stripeStatus = "succeeded"
        XCTAssertEqual(topUp.confirmationHTTPStatus, .accepted) // Stripe paid, accounting still pending.
        topUp.creditedAt = Date()
        XCTAssertEqual(topUp.confirmationHTTPStatus, .ok)
        XCTAssertEqual(topUp.status, "credited")
    }

    func testInvoiceAndEmailPreserveDepositDetailsAndHideInternalState() throws {
        var topUp = record()
        XCTAssertThrowsError(try EmailController.teamTopUpBody(topUp))
        topUp.paymentIntentID = "pi_fixture"; topUp.clientSecret = "secret_do_not_return"
        topUp.paidAt = Date(timeIntervalSince1970: 1789480800); topUp.creditedAt = Date()
        topUp.balanceBefore = -50; topUp.balanceAfter = 50
        let body = try EmailController.teamTopUpBody(topUp)
        XCTAssertTrue(body.contains("pi_fixture")); XCTAssertTrue(body.contains(topUp.invoiceNumber))
        XCTAssertTrue(body.contains("SANDBOX")); XCTAssertTrue(body.contains("Guthaben vorher:"))
        XCTAssertTrue(body.contains("100,00"))
        let response = TeamTopUpResponse(topUp, publishableKey: "pk_test_fixture")
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(json.contains("secret_do_not_return")); XCTAssertFalse(json.contains(topUp.recipient))
        let invoice = Rechnung(); invoice.paymentSource = "stripe"
        XCTAssertThrowsError(try invoice.requireManualEntry())
        let reply = try BSONDecoder().decode(UpdateReply.self, from: ["ok": 1, "n": 0, "nModified": 0,
            "writeErrors": [["index": 0, "code": 13, "errmsg": "denied"] as Document]])
        XCTAssertThrowsError(try reply.requireStripeWriteSuccess())
    }

    func testNetCreditWaitsForStripeFeesAndPreservesLegacyCredit() throws {
        var topUp = record(amount: 2000)
        XCTAssertEqual(try topUp.creditAmountMinor, 2000)
        topUp.creditPolicy = .stripeNet
        XCTAssertThrowsError(try topUp.creditAmountMinor)
        topUp.feeMinor = 55; topUp.netAmountMinor = 1945; topUp.balanceTransactionID = "txn_fixture"
        XCTAssertEqual(try topUp.creditAmountMinor, 1945)
        let result = TeamTopUpResponse(topUp, publishableKey: "pk_test_fixture")
        XCTAssertEqual(result.creditedAmountMinor, 1945); XCTAssertEqual(result.feeMinor, 55)
        topUp.netAmountMinor = 2000
        XCTAssertThrowsError(try topUp.creditAmountMinor)
        var input = TeamTopUpInput(amountMinor: 999, idempotencyKey: "net-test")
        input.creditPolicy = .stripeNet
        XCTAssertThrowsError(try input.validate(maximum: 500000))
        XCTAssertThrowsError(try input.validate(maximum: 50))
    }

    func testFeeTransactionMustMatchGrossCurrencyAndNet() throws {
        let valid = TeamStripeIntent.BalanceTransaction(id: "txn_fixture", amount: 2000, currency: "eur", fee: 55, net: 1945)
        XCTAssertNoThrow(try valid.validate(amountMinor: 2000))
        XCTAssertThrowsError(try valid.validate(amountMinor: 1000))
        XCTAssertThrowsError(try TeamStripeIntent.BalanceTransaction(id: "txn_fixture", amount: 2000, currency: "usd", fee: 55, net: 1945).validate(amountMinor: 2000))
        XCTAssertThrowsError(try TeamStripeIntent.BalanceTransaction(id: "txn_fixture", amount: 2000, currency: "eur", fee: -1, net: 2001).validate(amountMinor: 2000))
        XCTAssertThrowsError(try TeamStripeIntent.BalanceTransaction(id: "txn_fixture", amount: 2000, currency: "eur", fee: 55, net: 2000).validate(amountMinor: 2000))
    }

    func testCheckoutReturnPageDoesNotClaimPaymentSucceeded() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try app.register(collection: TeamPaymentController())
        try app.test(.GET, "payments/checkout/return?top_up_id=anything") {
            XCTAssertEqual($0.status, .ok)
            XCTAssertTrue($0.body.string.contains("oekfbapp://"))
            XCTAssertFalse($0.body.string.contains("anything"))
            XCTAssertFalse($0.body.string.contains("erfolgreich"))
        }
    }

    func testMongoDelayedFeesCreditNetExactlyOnce() async throws {
        try await withMongo { app, store, team, user in
            var topUp = self.record(teamID: try team.requireID(), userID: try user.requireID(), amount: 2000)
            topUp.creditPolicy = .stripeNet
            _ = try await store.insertOrGet(topUp)
            let manager = TeamTopUpManager(application: app, configuration: try self.config())
            let pendingFees = try JSONDecoder().decode(TeamStripeIntent.self, from: self.intentData(topUp))
            try await manager.recordVerified(pendingFees, for: topUp)
            do { try await store.credit(topUp.id); XCTFail("Fees missing must not credit") } catch {}
            let before = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(before?.balance, -50)
            var json = try JSONSerialization.jsonObject(with: self.intentData(topUp)) as! [String: Any]
            json["latest_charge"] = ["id": "ch_fixture", "created": 1789480800,
                "balance_transaction": ["id": "txn_fixture", "amount": 2000, "currency": "eur", "fee": 55, "net": 1945]] as [String: Any]
            let finalized = try JSONDecoder().decode(TeamStripeIntent.self, from: JSONSerialization.data(withJSONObject: json))
            let succeeded = try await store.get(topUp.id)
            try await manager.recordVerified(finalized, for: succeeded)
            try await store.credit(topUp.id)
            try await store.credit(topUp.id)
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance ?? 0, -30.55, accuracy: 0.00001)
            let invoice = try await Rechnung.find(topUp.invoiceID, on: app.db)
            XCTAssertEqual(invoice?.summ, 19.45)
            XCTAssertEqual(invoice?.stripeDeposit?.feeMinor, 55)
            let credited = try await store.get(topUp.id)
            let email = try EmailController.teamTopUpBody(credited)
            XCTAssertTrue(email.contains("Stripe-Gebühren")); XCTAssertTrue(email.contains("19,45"))
        }
    }

    // These tests use a unique database on a loopback-only disposable MongoDB, never configure(app).
    private func withMongo(_ run: (Application, TeamTopUpStore, Team, User) async throws -> Void) async throws {
        guard let port = Environment.get("STRIPE_TEST_MONGO_PORT"), Int(port) != nil else {
            throw XCTSkip("Set STRIPE_TEST_MONGO_PORT to an isolated local MongoDB port.")
        }
        let app = Application(.testing)
        app.logger.logLevel = .critical
        let name = "oekfb_stripe_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(name)"), as: .mongo)
        app.databases.middleware.use(TeamBalanceWriteMiddleware(), on: .mongo)
        app.databases.middleware.use(StripeInvoiceProtectionMiddleware(), on: .mongo)
        let store = TeamTopUpStore(database: app.db)
        defer { try? store.mongo.drop().wait(); app.shutdown() }
        try await TeamStripeTopUpMigration().prepare(on: app.db)
        let user = User(id: UUID(), userID: UUID().uuidString, type: .team, firstName: "Test", lastName: "Owner",
            email: "test@example.com", passwordHash: "hash")
        try await user.create(on: app.db)
        let team = Team(id: UUID(), sid: "TEST", userId: user.id, leagueId: nil, leagueCode: nil, points: 0,
            coverimg: "", logo: "", teamName: "Test Team", foundationYear: nil, membershipSince: nil,
            averageAge: "0", coach: nil, captain: nil, trikot: Trikot(home: "", away: ""), balance: -50,
            usremail: user.email, usrpass: nil, usrtel: nil)
        try await team.create(on: app.db)
        try await run(app, store, team, user)
    }

    private func paid(_ store: TeamTopUpStore, team: Team, user: User, amount: Int = 10000) async throws -> TeamTopUp {
        let topUp = record(teamID: try team.requireID(), userID: try user.requireID(), amount: amount)
        _ = try await store.insertOrGet(topUp)
        try await store.set(topUp.id, ["stripeStatus": "succeeded", "paidAt": Date(), "paymentIntentID": "pi_\(topUp.id)"])
        return try await store.get(topUp.id)
    }

    func testMongoConcurrentRetriesCreditOnceAndCreateOnePaidInvoice() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try await self.paid(store, team: team, user: user)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { try await store.credit(topUp.id) } }
                try await group.waitForAll()
            }
            let result = try await store.get(topUp.id)
            XCTAssertNotNil(result.creditedAt)
            XCTAssertEqual(result.balanceBefore, -50); XCTAssertEqual(result.balanceAfter, 50)
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, 50)
            let invoices = try await Rechnung.query(on: app.db).all()
            XCTAssertEqual(invoices.count, 1); XCTAssertEqual(invoices.first?.status, .bezahlt)
            XCTAssertEqual(invoices.first?.topay, 0); XCTAssertEqual(invoices.first?.paymentSource, "stripe")
            try await store.credit(topUp.id)
            let afterReplay = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(afterReplay?.balance, 50)
        }
    }

    func testMongoLegacyDebitCannotOverwriteConcurrentCredit() async throws {
        try await withMongo { app, store, team, user in
            let loaded = try await Team.find(team.id, on: app.db)
            let stale = try XCTUnwrap(loaded)
            XCTAssertTrue(stale.hasLoadedBalance); XCTAssertEqual(stale.loadedBalance, -50)
            stale.balance = (stale.balance ?? 0) - 5
            let first = try await self.paid(store, team: team, user: user)
            let second = try await self.paid(store, team: team, user: user, amount: 2000)
            async let a: Void = store.credit(first.id)
            async let b: Void = store.credit(second.id)
            _ = try await (a, b)
            try await stale.save(on: app.db)
            let result = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(result?.balance, 65) // -50 + 100 + 20 - 5
            stale.teamName = "Updated name"
            try await stale.save(on: app.db)
            let afterSecondSave = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(afterSecondSave?.balance, 65)
        }
    }

    func testMongoRecoveryFinishesAppliedCreditWithoutAddingAgain() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try await self.paid(store, team: team, user: user)
            let marker = PendingTeamStripeCredit(topUpID: topUp.id, before: -50, after: 50, creditedAt: Date())
            // Simulate a process dying after the atomic balance write and before creating the invoice.
            _ = try await store.collection(Team.schema).stripeUpdate(where: ["_id": try TeamTopUpStore.uuid(team.requireID())],
                to: ["$set": ["balance": 50.0, "stripeCreditVersion": 1,
                    "pendingStripeCredit": try BSONEncoder().encode(marker)] as Document]).get()
            try await store.credit(topUp.id)
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, 50)
            let invoice = try await Rechnung.find(topUp.invoiceID, on: app.db)
            XCTAssertNotNil(invoice)
            let raw = try await store.collection(Team.schema).findOne(["_id": try TeamTopUpStore.uuid(team.requireID())]).get()
            XCTAssertNil(raw?["pendingStripeCredit"])
            let credited = try await store.get(topUp.id)
            XCTAssertNotNil(credited.creditedAt)
            do { try await invoice!.delete(on: app.db); XCTFail("Stripe invoice must be immutable") } catch {}
        }
    }

    func testMongoFailedEmailRetriesWithoutAnotherCredit() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try await self.paid(store, team: team, user: user)
            try await store.credit(topUp.id)
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), sendEmail: { _ in throw Abort(.badGateway) })
            do { try await manager.process(id: topUp.id); XCTFail("Expected mail failure") } catch {}
            let failed = try await store.get(topUp.id)
            XCTAssertNotNil(failed.creditedAt); XCTAssertNil(failed.emailSentAt)
            let retry = TeamTopUpManager(application: app, configuration: try self.config(), sendEmail: { _ in })
            try await retry.process(id: topUp.id)
            let sent = try await store.get(topUp.id)
            XCTAssertNotNil(sent.emailSentAt)
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, 50)
        }
    }

    func testMongoCreateRetryUsesSameStripeIdempotencyKeyAfterLostResponse() async throws {
        try await withMongo { app, store, team, user in
            let input = TeamTopUpInput(amountMinor: 10000, idempotencyKey: "same-request")
            let topUp = TeamTopUp(teamID: try team.requireID(), userID: try user.requireID(), teamName: team.teamName,
                recipient: user.email, input: input, livemode: false)
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.intentData(topUp, status: "requires_payment_method"), failFirst: true)
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock)
            do { _ = try await manager.create(team: team, user: user, input: input); XCTFail("Expected lost response") } catch {}
            let response = try await manager.create(team: team, user: user, input: input)
            XCTAssertNotNil(response.clientSecret); XCTAssertEqual(response.id, topUp.id)
            XCTAssertEqual(mock.requests.count, 2)
            XCTAssertEqual(mock.requests.first?.headers.first(name: "Idempotency-Key"), mock.requests.last?.headers.first(name: "Idempotency-Key"))
            XCTAssertTrue(String(buffer: try XCTUnwrap(mock.requests.last?.body)).contains("amount=10000"))
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, -50)
            do {
                _ = try await manager.create(team: team, user: user, input: TeamTopUpInput(amountMinor: 20000, idempotencyKey: input.idempotencyKey))
                XCTFail("Key/amount mismatch should fail")
            } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
        }
    }

    func testMongoEarlySignedWebhookBindsPaymentAndDuplicateDoesNotCreditAgain() async throws {
        try await withMongo { app, store, team, user in
            let topUp = self.record(teamID: try team.requireID(), userID: try user.requireID())
            _ = try await store.insertOrGet(topUp) // No PaymentIntent ID saved yet.
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.intentData(topUp))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock, sendEmail: { _ in })
            let event = try JSONSerialization.data(withJSONObject: ["id": "evt_early", "type": "payment_intent.succeeded",
                "livemode": false, "data": ["object": ["id": "pi_\(topUp.id)", "metadata": ["kind": "oekfb_team_top_up", "top_up_id": topUp.id]]]])
            let header = self.signature(event, timestamp: Int(Date().timeIntervalSince1970))
            try await manager.receiveWebhook(body: event, signature: header)
            for _ in 0..<100 {
                if try await store.get(topUp.id).emailSentAt != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let first = try await store.get(topUp.id)
            XCTAssertNotNil(first.creditedAt); XCTAssertNotNil(first.emailSentAt)
            try await manager.receiveWebhook(body: event, signature: header)
            try await manager.drainEvents()
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, 50)
            let invoices = try await Rechnung.query(on: app.db).count()
            XCTAssertEqual(invoices, 1)
        }
    }

    func testMongoFailedOrMismatchedPaymentCannotCreditAndSuccessCannotRegress() async throws {
        try await withMongo { app, store, team, user in
            let topUp = self.record(teamID: try team.requireID(), userID: try user.requireID())
            _ = try await store.insertOrGet(topUp)
            let manager = TeamTopUpManager(application: app)
            let failed = try JSONDecoder().decode(TeamStripeIntent.self, from: self.intentData(topUp, status: "requires_payment_method"))
            try await manager.recordVerified(failed, for: topUp)
            do { try await store.credit(topUp.id); XCTFail("Unpaid deposit must not be credited") } catch {}
            let wrong = try JSONDecoder().decode(TeamStripeIntent.self, from: self.intentData(topUp, amount: 1))
            do { try await manager.recordVerified(wrong, for: topUp); XCTFail("Mismatch must fail") } catch {}
            let success = try JSONDecoder().decode(TeamStripeIntent.self, from: self.intentData(topUp))
            try await manager.recordVerified(success, for: topUp)
            try await manager.recordVerified(failed, for: topUp) // Late, stale failed event.
            let stored = try await store.get(topUp.id)
            XCTAssertEqual(stored.stripeStatus, "succeeded")
            try await store.credit(topUp.id)
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, 50)
        }
    }

    func testMongoCheckoutRetryPreservesLinkRequestAndRejectsSDKKeyReuse() async throws {
        try await withMongo { app, store, team, user in
            let input = TeamTopUpInput(amountMinor: 10000, idempotencyKey: "checkout-lost-response")
            let topUp = try self.checkoutRecord(teamID: team.requireID(), userID: user.requireID(), key: input.idempotencyKey)
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.checkoutData(topUp), failFirst: true)
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock)
            do { _ = try await manager.create(team: team, user: user, input: input, flow: .checkout); XCTFail("Expected lost response") } catch {}
            let newConfig = try self.config(overrides: ["STRIPE_CHECKOUT_SUCCESS_URL": "https://app.example.com/new-return"])
            let retry = TeamTopUpManager(application: app, configuration: newConfig, client: mock)
            let response = try await retry.create(team: team, user: user, input: input, flow: .checkout)
            XCTAssertNotNil(response.checkoutUrl); XCTAssertNil(response.clientSecret)
            XCTAssertEqual(response.paymentFlow, .checkout); XCTAssertEqual(response.status, "open")
            XCTAssertEqual(mock.requests.count, 2)
            XCTAssertTrue(mock.requests.allSatisfy { $0.url.path == "/v1/checkout/sessions" && $0.method == .POST })
            XCTAssertEqual(mock.requests.first?.body, mock.requests.last?.body)
            XCTAssertEqual(mock.requests.first?.headers.first(name: "Idempotency-Key"), "oekfb-checkout-\(topUp.id)")
            let form = String(buffer: try XCTUnwrap(mock.requests.last?.body)).removingPercentEncoding ?? ""
            XCTAssertTrue(form.contains("line_items[0][price_data][unit_amount]=10000"))
            XCTAssertTrue(form.contains("payment_intent_data[metadata][top_up_id]=\(topUp.id)"))
            XCTAssertTrue(form.contains("metadata[team_id]=\(team.id!.uuidString)"))
            XCTAssertTrue(form.contains("success_url=https://app.example.com/finance/success?top_up_id=\(topUp.id)"))
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, -50)
            let invoices = try await Rechnung.query(on: app.db).count()
            XCTAssertEqual(invoices, 0)
            do {
                _ = try await manager.create(team: team, user: user, input: input)
                XCTFail("The same key cannot create another SDK payment")
            } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
            XCTAssertEqual(mock.requests.count, 2)
        }
    }

    func testMongoCheckoutUnpaidCompletionWaitsThenMixedWebhooksCreditOnce() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try self.checkoutRecord(teamID: team.requireID(), userID: user.requireID())
            _ = try await store.insertOrGet(topUp) // The session webhook arrives before its API response was saved.
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(),
                response: try self.checkoutData(topUp, status: "complete", hasIntent: true),
                paymentResponse: try self.intentData(topUp, status: "processing"))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock, sendEmail: { _ in })
            try await self.sendEvent(manager, topUp: topUp, type: "checkout.session.completed", eventID: "evt_checkout_complete")
            for _ in 0..<200 {
                let current = try await store.get(topUp.id)
                if current.stripeStatus == "processing" && current.leaseUntil < Date() { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let unpaid = try await store.get(topUp.id)
            XCTAssertEqual(unpaid.checkoutSessionID, "cs_test_\(topUp.id)")
            XCTAssertEqual(unpaid.stripeStatus, "processing"); XCTAssertNil(unpaid.creditedAt); XCTAssertNil(unpaid.emailSentAt)
            XCTAssertEqual(unpaid.confirmationHTTPStatus, .accepted)
            XCTAssertTrue(mock.requests.allSatisfy { $0.method == .GET })
            let balanceBefore = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(balanceBefore?.balance, -50)
            mock.setResponses(try self.checkoutData(topUp, status: "complete", paymentStatus: "paid", hasIntent: true),
                payment: try self.intentData(topUp))
            try await self.sendEvent(manager, topUp: topUp, type: "checkout.session.async_payment_succeeded", eventID: "evt_checkout_paid")
            try await self.sendEvent(manager, topUp: topUp, type: "payment_intent.succeeded", eventID: "evt_checkout_intent_paid")
            for _ in 0..<200 {
                let current = try await store.get(topUp.id)
                if current.emailSentAt != nil && current.leaseUntil < Date() { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await manager.drainEvents()
            let credited = try await store.get(topUp.id)
            XCTAssertEqual(credited.confirmationHTTPStatus, .ok); XCTAssertNotNil(credited.emailSentAt)
            XCTAssertEqual(credited.balanceAfter, 50)
            try await self.sendEvent(manager, topUp: topUp, type: "checkout.session.async_payment_succeeded", eventID: "evt_checkout_paid")
            try await manager.drainEvents()
            let balance = try await Team.find(team.id, on: app.db)
            let invoices = try await Rechnung.query(on: app.db).all()
            XCTAssertEqual(balance?.balance, 50); XCTAssertEqual(invoices.count, 1)
            XCTAssertEqual(invoices.first?.paymentSource, "stripe")
        }
    }

    func testMongoCheckoutExpiredAndDeclinedPaymentsDoNotCredit() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try self.checkoutRecord(teamID: team.requireID(), userID: user.requireID())
            _ = try await store.insertOrGet(topUp)
            try await store.set(topUp.id, ["checkoutSessionID": "cs_test_\(topUp.id)"])
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.checkoutData(topUp, hasIntent: true),
                paymentResponse: try self.intentData(topUp, status: "requires_payment_method", failed: true))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock, sendEmail: { _ in XCTFail("Unpaid email") })
            try await manager.process(id: topUp.id)
            let declined = try await store.get(topUp.id)
            XCTAssertEqual(declined.confirmationHTTPStatus, .paymentRequired); XCTAssertNil(declined.creditedAt)
            mock.setResponses(try self.checkoutData(topUp, status: "expired", hasIntent: true),
                payment: try self.intentData(topUp, status: "canceled"))
            try await manager.process(id: topUp.id)
            let expired = try await store.get(topUp.id)
            XCTAssertEqual(expired.confirmationHTTPStatus, .gone); XCTAssertNil(expired.creditedAt)
            XCTAssertGreaterThan(expired.nextAttemptAt, Date().addingTimeInterval(365 * 86400))
            XCTAssertNil(TeamTopUpResponse(expired, publishableKey: "pk_test_fixture").checkoutUrl)
            let balance = try await Team.find(team.id, on: app.db)
            let invoices = try await Rechnung.query(on: app.db).count()
            XCTAssertEqual(balance?.balance, -50); XCTAssertEqual(invoices, 0)
        }
    }

    func testMongoCheckoutPaidSessionStillRequiresMatchingSuccessfulIntent() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try self.checkoutRecord(teamID: team.requireID(), userID: user.requireID())
            _ = try await store.insertOrGet(topUp)
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(),
                response: try self.checkoutData(topUp, status: "complete", paymentStatus: "paid", hasIntent: true),
                paymentResponse: try self.intentData(topUp, status: "processing"))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock, sendEmail: { _ in XCTFail("Unverified email") })
            try await manager.process(id: topUp.id)
            let pending = try await store.get(topUp.id)
            XCTAssertEqual(pending.confirmationHTTPStatus, .accepted)
            mock.setResponses(try self.checkoutData(topUp, status: "complete", paymentStatus: "paid", hasIntent: true),
                payment: try self.intentData(topUp, amount: 1))
            do { try await manager.process(id: topUp.id); XCTFail("Intent amount mismatch must fail") }
            catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
            let uncredited = try await store.get(topUp.id)
            XCTAssertNil(uncredited.creditedAt)
            let balance = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(balance?.balance, -50)
        }
    }

    func testMongoCheckoutEarlyIntentEventRecoversWithoutCreatingAnotherPayment() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try self.checkoutRecord(teamID: team.requireID(), userID: user.requireID())
            _ = try await store.insertOrGet(topUp)
            try await store.set(topUp.id, ["createdAt": Date().addingTimeInterval(-25 * 3600)])
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.intentData(topUp))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock, sendEmail: { _ in })
            try await self.sendEvent(manager, topUp: topUp, type: "payment_intent.succeeded", eventID: "evt_checkout_early_intent")
            for _ in 0..<200 {
                let current = try await store.get(topUp.id)
                if current.emailSentAt != nil && current.leaseUntil < Date() { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let credited = try await store.get(topUp.id)
            XCTAssertEqual(credited.status, "credited"); XCTAssertNotNil(credited.emailSentAt)
            XCTAssertFalse(mock.requests.isEmpty)
            XCTAssertTrue(mock.requests.allSatisfy { $0.method == .GET && $0.url.path.hasPrefix("/v1/payment_intents/") })
        }
    }

    func testMongoCheckoutAmbiguousExpiredCreationNeedsReview() async throws {
        try await withMongo { app, store, team, user in
            let topUp = try self.checkoutRecord(teamID: team.requireID(), userID: user.requireID())
            _ = try await store.insertOrGet(topUp)
            try await store.set(topUp.id, ["createdAt": Date().addingTimeInterval(-24 * 3600)])
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.checkoutData(topUp))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock)
            try await manager.process(id: topUp.id)
            let result = try await store.get(topUp.id)
            XCTAssertTrue(result.needsReview); XCTAssertTrue(mock.requests.isEmpty)
        }
    }

    func testMongoExpiredAmbiguousCreationDoesNotMakeAnotherStripeRequest() async throws {
        try await withMongo { app, store, team, user in
            let topUp = TeamTopUp(teamID: try team.requireID(), userID: try user.requireID(), teamName: team.teamName,
                recipient: user.email, input: TeamTopUpInput(amountMinor: 10000, idempotencyKey: "old-request"),
                livemode: false, now: Date().addingTimeInterval(-24 * 3600))
            _ = try await store.insertOrGet(topUp)
            let mock = TopUpMockClient(eventLoop: app.eventLoopGroup.next(), response: try self.intentData(topUp))
            let manager = TeamTopUpManager(application: app, configuration: try self.config(), client: mock)
            try await manager.process(id: topUp.id)
            let result = try await store.get(topUp.id)
            XCTAssertTrue(result.needsReview); XCTAssertTrue(mock.requests.isEmpty)
            let current = try await Team.find(team.id, on: app.db)
            XCTAssertEqual(current?.balance, -50)
        }
    }
}

private final class TopUpMockClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    private var response: Data
    private var paymentResponse: Data?
    let failFirst: Bool
    private let lock = NSLock()
    private var captured = [ClientRequest]()
    var requests: [ClientRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    init(eventLoop: EventLoop, response: Data, failFirst: Bool = false, paymentResponse: Data? = nil) {
        self.eventLoop = eventLoop; self.response = response; self.failFirst = failFirst; self.paymentResponse = paymentResponse
    }
    func setResponses(_ response: Data, payment: Data? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.response = response; paymentResponse = payment
    }
    func delegating(to eventLoop: EventLoop) -> Client { self }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        lock.lock(); captured.append(request); let fail = failFirst && captured.count == 1
        let data = request.url.path.hasPrefix("/v1/payment_intents/") ? paymentResponse ?? response : response
        lock.unlock()
        if fail { return eventLoop.makeFailedFuture(Abort(.gatewayTimeout)) }
        return eventLoop.makeSucceededFuture(ClientResponse(status: .ok, body: ByteBuffer(data: data)))
    }
}
