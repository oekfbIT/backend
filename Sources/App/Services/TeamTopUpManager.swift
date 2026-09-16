import Fluent
import MongoKitten
import Queues
import Vapor

struct TeamTopUpManager {
    let application: Application
    private let configurationOverride: TeamStripeConfiguration?
    private let clientOverride: Client?
    private let emailOverride: ((TeamTopUp) async throws -> Void)?
    var store: TeamTopUpStore { TeamTopUpStore(database: application.db) }
    private var configuration: TeamStripeConfiguration { get throws { try configurationOverride ?? TeamStripeConfiguration() } }

    init(application: Application, configuration: TeamStripeConfiguration? = nil, client: Client? = nil,
         sendEmail: ((TeamTopUp) async throws -> Void)? = nil) {
        self.application = application; configurationOverride = configuration
        clientOverride = client; emailOverride = sendEmail
    }

    func create(team: Team, user: User, input: TeamTopUpInput, flow: TeamTopUpPaymentFlow = .sdk) async throws -> TeamTopUpResponse {
        let configuration = try self.configuration
        try input.validate(maximum: configuration.maximumMinor)
        let owner = try await team.$user.get(on: application.db)
        guard let recipient = owner?.email, !recipient.isEmpty else {
            throw Abort(.conflict, reason: "The team needs an account email before accepting a top-up.")
        }
        var proposed = TeamTopUp(teamID: try team.requireID(), userID: try user.requireID(),
            teamName: team.teamName, recipient: recipient, input: input, livemode: configuration.livemode)
        proposed.paymentFlow = flow
        if flow == .checkout {
            let urls = try configuration.checkoutReturnURLs(topUpID: proposed.id)
            // Snapshot request parameters so recovery uses the identical Stripe idempotency request.
            proposed.checkoutSuccessURL = urls.success; proposed.checkoutCancelURL = urls.cancel
        }
        let existing = try await store.insertOrGet(proposed)
        guard existing.amountMinor == input.amountMinor, existing.flow == flow, existing.effectiveCreditPolicy == proposed.effectiveCreditPolicy else {
            throw Abort(.conflict, reason: "This idempotency key was already used for a different amount, payment flow or credit policy.")
        }
        // Return a usable PaymentIntent or Checkout URL. Lost responses recover with the same key.
        try await process(id: existing.id, sendEmail: false)
        return TeamTopUpResponse(try await store.get(existing.id), publishableKey: configuration.publishableKey)
    }

    func receiveWebhook(body: Data, signature: String) async throws {
        let config = try configuration
        try TeamStripeClient.verifySignature(body: body, header: signature, secret: config.webhookSecret)
        struct Event: Decodable {
            let id: String; let type: String; let livemode: Bool; let data: Payload
            struct Payload: Decodable { let object: Object }
            struct Object: Decodable { let id: String; let metadata: [String: String]? }
        }
        let event: Event
        do { event = try JSONDecoder().decode(Event.self, from: body) }
        catch { throw Abort(.badRequest, reason: "Invalid Stripe event payload.") }
        guard event.livemode == config.livemode else { throw Abort(.badRequest, reason: "Stripe event mode does not match this backend.") }
        let checkoutEvent = ["checkout.session.completed", "checkout.session.async_payment_succeeded",
            "checkout.session.async_payment_failed", "checkout.session.expired"].contains(event.type)
        guard checkoutEvent || ["payment_intent.succeeded", "payment_intent.payment_failed", "payment_intent.canceled"].contains(event.type),
              event.data.object.metadata?["kind"] == "oekfb_team_top_up",
              let id = event.data.object.metadata?["top_up_id"] else { return }
        let events = try store.collection("team_stripe_events")
        var document: Document = ["_id": event.id, "topUpID": id, "eventType": event.type,
            "receivedAt": Date(), "pending": true]
        document[checkoutEvent ? "checkoutSessionID" : "paymentIntentID"] = event.data.object.id
        do { _ = try await events.stripeUpsert(["$setOnInsert": document], where: ["_id": event.id]).get() }
        catch {
            guard try await events.findOne(["_id": event.id]).get() != nil else { throw error }
        }
        // The durable inbox is the guarantee. This task only reduces latency; the scheduled worker recovers it.
        Task {
            do { try await drainEvents() }
            catch { application.logger.error("Stripe top-up inbox processing failed; scheduled recovery will retry.") }
        }
    }

    func drainEvents() async throws {
        let events = try store.collection("team_stripe_events")
        let pending = try await events.find(["pending": true]).sort(["receivedAt": 1]).limit(100).allResults().get()
        for event in pending {
            guard let id = event["topUpID"] as? String,
                  let eventID = event["_id"] as? String else { continue }
            do {
                let topUp = try await store.get(id)
                let checkoutID = event["checkoutSessionID"] as? String
                let field = checkoutID == nil ? "paymentIntentID" : "checkoutSessionID"
                guard let objectID = checkoutID ?? event["paymentIntentID"] as? String else { continue }
                let existingID = checkoutID == nil ? topUp.paymentIntentID : topUp.checkoutSessionID
                guard (checkoutID == nil || topUp.flow == .checkout),
                      existingID == nil || existingID == objectID else {
                    throw Abort(.conflict, reason: "Stripe event payment mismatch.")
                }
                // Binding is conditional; a signed event may arrive before create() saves its API response.
                let bound = try await store.collection(TeamTopUp.schema).findOneAndUpdate(where: ["_id": id,
                    "$or": [[field: Null()] as Document, [field: objectID] as Document]],
                    to: ["$set": [field: objectID, "nextAttemptAt": Date(), "needsReview": false] as Document])
                    .stripeExecute().get()
                guard bound != nil else { throw Abort(.conflict) }
                _ = try await events.stripeUpdate(where: ["_id": eventID], to: ["$set": ["pending": false]]).get()
                try await process(id: id)
            } catch {
                application.logger.warning("Stripe top-up event \(eventID) will be retried or requires review.")
            }
        }
    }

    func recover() async throws {
        guard let config = try? configuration else { return }
        try await drainEvents()
        let now = Date()
        let due = try await store.collection(TeamTopUp.schema).find([
            "livemode": config.livemode, "needsReview": false, "nextAttemptAt": ["$lte": now], "leaseUntil": ["$lte": now]
        ]).sort(["nextAttemptAt": 1]).limit(100).decode(TeamTopUp.self).allResults().get()
        for topUp in due {
            do { try await process(id: topUp.id) }
            catch { application.logger.warning("Stripe top-up \(topUp.id) recovery will retry.") }
        }
    }

    func process(id: String, sendEmail: Bool = true) async throws {
        let config = try configuration
        let collection = try store.collection(TeamTopUp.schema)
        let token = UUID().uuidString
        let claim = try await collection.findOneAndUpdate(where: ["_id": id,
            "livemode": config.livemode, "needsReview": false, "leaseUntil": ["$lte": Date()]],
            to: ["$set": ["leaseUntil": Date().addingTimeInterval(180), "leaseOwner": token] as Document]).stripeExecute().get()
        guard claim != nil else { return }
        do {
            var topUp = try await store.get(id)
            if topUp.creditedAt == nil {
                let stripe = TeamStripeClient(client: clientOverride ?? application.client, configuration: config)
                if topUp.paymentIntentID == nil && topUp.checkoutSessionID == nil {
                    // Stripe idempotency keys can expire after 24h. Never blindly create a second charge.
                    guard Date().timeIntervalSince(topUp.createdAt) < 23 * 3600 else {
                        try await store.set(id, ["needsReview": true, "lastError": "Payment creation was interrupted. Find the Stripe payment or Checkout Session using metadata.top_up_id before retrying."])
                        try await release(id, token: token)
                        return
                    }
                }
                if topUp.flow == .checkout {
                    if let sessionID = topUp.checkoutSessionID {
                        try await recordVerified(stripe.retrieveCheckout(sessionID), for: topUp)
                    } else if topUp.paymentIntentID == nil {
                        try await recordVerified(stripe.createCheckout(topUp), for: topUp)
                    }
                    // A PaymentIntent event can arrive before the Checkout creation response/session event.
                    // Its independently verified payment is sufficient; never create a separate SDK payment.
                    topUp = try await store.get(id)
                    if let paymentID = topUp.paymentIntentID {
                        try await recordVerified(stripe.retrieve(paymentID), for: topUp)
                    }
                } else {
                    let intent: TeamStripeIntent
                    if let paymentID = topUp.paymentIntentID { intent = try await stripe.retrieve(paymentID) }
                    else { intent = try await stripe.create(topUp) }
                    try await recordVerified(intent, for: topUp)
                }
                topUp = try await store.get(id)
            }
            if topUp.stripeStatus == "succeeded" { try await store.credit(id) }
            topUp = try await store.get(id)
            if sendEmail, topUp.creditedAt != nil, topUp.emailSentAt == nil {
                // SMTP is at-least-once: a crash after delivery but before this write may repeat the email.
                if let send = emailOverride { try await send(topUp) }
                else { try await EmailController().sendTeamTopUpConfirmation(application: application, topUp: topUp) }
                try await store.set(id, ["emailSentAt": Date()])
            }
            topUp = try await store.get(id)
            let finished = (topUp.creditedAt != nil && topUp.emailSentAt != nil) ||
                topUp.stripeStatus == "canceled" || topUp.status == "expired"
            let delay: TimeInterval = topUp.creditedAt != nil ? 60 : min(3600, max(60, Date().timeIntervalSince(topUp.createdAt) / 4))
            try await store.set(id, ["nextAttemptAt": finished ? Date.distantFuture : Date().addingTimeInterval(delay), "lastError": Null()])
            try await release(id, token: token)
        } catch {
            try? await store.set(id, ["nextAttemptAt": Date().addingTimeInterval(60),
                "lastError": "Processing or email delivery failed. Background recovery will retry."])
            try? await release(id, token: token)
            throw error
        }
    }

    /// All success paths verify the authoritative PaymentIntent before touching the balance.
    func recordVerified(_ intent: TeamStripeIntent, for topUp: TeamTopUp) async throws {
        try intent.validate(for: topUp)
        var fields: Document = ["paymentIntentID": intent.id, "stripeStatus": intent.status,
            "paymentFailed": intent.last_payment_error != nil]
        if let secret = intent.client_secret { fields["clientSecret"] = secret }
        if intent.status == "succeeded" {
            fields["paidAt"] = topUp.paidAt ?? intent.latest_charge?.created.map(Date.init(timeIntervalSince1970:)) ?? Date()
            if let charge = intent.latest_charge { fields["chargeID"] = charge.id }
            if topUp.effectiveCreditPolicy == .stripeNet, let transaction = intent.latest_charge?.balance_transaction {
                try transaction.validate(amountMinor: topUp.amountMinor)
                // Save the first verified fee once; stale workers cannot change a credit in progress.
                _ = try await store.collection(TeamTopUp.schema).stripeUpdate(where: ["_id": topUp.id,
                    "creditedAt": Null(), "balanceTransactionID": Null(),
                    "$or": [["paymentIntentID": Null()] as Document, ["paymentIntentID": intent.id] as Document]],
                    to: ["$set": ["paymentIntentID": intent.id, "feeMinor": transaction.fee,
                        "netAmountMinor": transaction.net, "balanceTransactionID": transaction.id] as Document]).get()
            }
        }
        // A slow worker must not regress a previously confirmed success.
        var filter: Document = ["_id": topUp.id, "creditedAt": Null(),
            "$or": [["paymentIntentID": Null()] as Document, ["paymentIntentID": intent.id] as Document]]
        // Stripe can populate fees AFTER succeeded. Permit that enrichment without regressing success.
        if intent.status != "succeeded" { filter["stripeStatus"] = ["$ne": "succeeded"] as Document }
        _ = try await store.collection(TeamTopUp.schema).stripeUpdate(where: filter, to: ["$set": fields]).get()
    }

    /// Checkout completion can still be unpaid. Only record the session/binding here; credit uses the verified intent.
    func recordVerified(_ session: TeamStripeCheckoutSession, for topUp: TeamTopUp) async throws {
        try session.validate(for: topUp)
        var fields: Document = ["checkoutSessionID": session.id, "checkoutStatus": session.status,
            "checkoutExpiresAt": Date(timeIntervalSince1970: session.expires_at),
            "checkoutURL": session.url.map { $0 as Primitive } ?? Null()]
        var bindings: [Document] = [["$or": [["checkoutSessionID": Null()] as Document,
            ["checkoutSessionID": session.id] as Document]]]
        if let paymentID = session.payment_intent?.id {
            fields["paymentIntentID"] = paymentID
            bindings.append(["$or": [["paymentIntentID": Null()] as Document, ["paymentIntentID": paymentID] as Document]])
        }
        _ = try await store.collection(TeamTopUp.schema).stripeUpdate(where: ["_id": topUp.id, "$and": bindings],
            to: ["$set": fields]).get()
        let updated = try await store.get(topUp.id)
        try session.validate(for: updated)
        if session.payment_intent == nil {
            _ = try await store.collection(TeamTopUp.schema).stripeUpdate(where: ["_id": topUp.id,
                "paymentIntentID": Null(), "creditedAt": Null(), "stripeStatus": ["$ne": "succeeded"]],
                to: ["$set": ["stripeStatus": session.status == "complete" ? "processing" : session.status]]).get()
        }
    }

    private func release(_ id: String, token: String) async throws {
        _ = try await store.collection(TeamTopUp.schema).stripeUpdate(where: ["_id": id, "leaseOwner": token],
            to: ["$set": ["leaseUntil": Date.distantPast], "$unset": ["leaseOwner": 1]]).get()
    }
}

struct TeamTopUpRecoveryJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        try await TeamTopUpManager(application: context.application).recover()
    }
}
