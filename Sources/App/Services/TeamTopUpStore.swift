import Fluent
import FluentMongoDriver
import MongoKitten
import Vapor

extension UpdateReply {
    func requireStripeWriteSuccess() throws {
        guard ok == 1, writeConcernError == nil, (writeErrors ?? []).isEmpty else { throw self }
    }
}

extension MongoCollection {
    func stripeUpdate(where query: Document, to document: Document) -> EventLoopFuture<UpdateReply> {
        updateOne(where: query, to: document).flatMapThrowing { reply in
            try reply.requireStripeWriteSuccess(); return reply
        }
    }
    func stripeUpsert(_ document: Document, where query: Document) -> EventLoopFuture<UpdateReply> {
        upsert(document, where: query).flatMapThrowing { reply in
            try reply.requireStripeWriteSuccess(); return reply
        }
    }
}

extension FindAndModifyBuilder {
    func stripeExecute() -> EventLoopFuture<Document?> {
        execute().flatMapThrowing { reply in
            guard reply.ok == 1 else { throw reply }
            return reply.value
        }
    }
}

struct PendingTeamStripeCredit: Codable {
    let topUpID: String
    let before: Double
    let after: Double
    let creditedAt: Date
}

/// Only one recovery marker per team; the permanent audit record lives in TeamTopUp/Rechnung.
struct TeamTopUpStore {
    let database: Database

    var mongo: MongoDatabase {
        get throws {
            guard let database = database as? MongoDatabaseRepresentable else {
                throw Abort(.serviceUnavailable, reason: "Team top-ups require MongoDB.")
            }
            return database.raw
        }
    }

    func collection(_ name: String) throws -> MongoCollection { try mongo[name] }
    static func uuid(_ id: UUID) throws -> Primitive { try BSONEncoder().encodePrimitive(id)! }

    func get(_ id: String) async throws -> TeamTopUp {
        guard let record = try await collection(TeamTopUp.schema).findOne(["_id": id], as: TeamTopUp.self).get() else {
            throw Abort(.notFound, reason: "Top-up not found.")
        }
        return record
    }

    func insertOrGet(_ record: TeamTopUp) async throws -> TeamTopUp {
        // $setOnInsert plus the deterministic Mongo _id makes concurrent client retries safe.
        let document = try BSONEncoder().encode(record)
        do {
            _ = try await collection(TeamTopUp.schema).stripeUpsert(["$setOnInsert": document], where: ["_id": record.id]).get()
        } catch {
            // A racing upsert can report a duplicate key; only accept an existing matching record.
            guard let existing = try? await get(record.id) else { throw error }
            return existing
        }
        return try await get(record.id)
    }

    func set(_ id: String, _ fields: Document) async throws {
        _ = try await collection(TeamTopUp.schema).stripeUpdate(where: ["_id": id], to: ["$set": fields]).get()
    }

    /// Reads the team BEFORE re-reading the deposit. The monotonic version fences stale workers
    /// even after the recovery marker is removed. Never reverse that read order.
    func credit(_ id: String) async throws {
        let initial = try await get(id)
        let teams = try collection(Team.schema)
        let teamKey = try Self.uuid(initial.teamID)
        for _ in 0..<20 {
            guard let team = try await teams.findOne(["_id": teamKey]).get() else {
                throw Abort(.notFound, reason: "Top-up team no longer exists; payment needs administrator review.")
            }
            if let pendingDocument = team["pendingStripeCredit"] as? Document {
                try await finish(try BSONDecoder().decode(PendingTeamStripeCredit.self, from: pendingDocument))
                continue
            }
            let topUp = try await get(id)
            if topUp.creditedAt != nil { return }
            guard topUp.stripeStatus == "succeeded", topUp.paidAt != nil else {
                throw Abort(.conflict, reason: "Stripe has not confirmed this top-up.")
            }
            let creditedMinor = try topUp.creditAmountMinor
            let before = try Self.balance(in: team)
            let pending = PendingTeamStripeCredit(topUpID: id, before: before,
                after: before + Double(creditedMinor) / 100, creditedAt: Date())
            let filter: Document = ["_id": teamKey,
                "balance": team["balance"] ?? Null(),
                "stripeCreditVersion": team["stripeCreditVersion"] ?? Null(),
                "pendingStripeCredit": Null()]
            let changes: Document = ["$set": ["balance": pending.after,
                "pendingStripeCredit": try BSONEncoder().encode(pending)] as Document, "$inc": ["stripeCreditVersion": 1]]
            if try await teams.findOneAndUpdate(where: filter, to: changes).stripeExecute().get() != nil {
                try await finish(pending)
                return
            }
        }
        throw Abort(.conflict, reason: "Team balance is busy; the top-up will retry in the background.")
    }

    private func finish(_ pending: PendingTeamStripeCredit) async throws {
        let topUp = try await get(pending.topUpID)
        guard let intentID = topUp.paymentIntentID, let paidAt = topUp.paidAt else {
            throw Abort(.conflict, reason: "Incomplete Stripe credit record.")
        }
        if try await Rechnung.find(topUp.invoiceID, on: database) == nil {
            let invoice = Rechnung(id: topUp.invoiceID, team: topUp.teamID, teamName: topUp.teamName,
                status: .bezahlt, number: topUp.invoiceNumber, summ: Double(try topUp.creditAmountMinor) / 100,
                topay: 0, previousBalance: pending.before, kennzeichen: "Guthaben Einzahlung – Stripe", created: paidAt)
            invoice.paymentSource = "stripe"
            invoice.dueDate = nil
            invoice.stripeDeposit = StripeDepositDetails(topUpId: topUp.id, paymentIntentId: intentID,
                chargeId: topUp.chargeID, amountMinor: topUp.amountMinor, currency: "eur", paidAt: paidAt,
                balanceAfter: pending.after, livemode: topUp.livemode,
                feeMinor: topUp.feeMinor, creditedAmountMinor: try topUp.creditAmountMinor)
            invoice.allowsStripeCreation = true
            do { try await invoice.create(on: database) }
            catch {
                guard let existing = try await Rechnung.find(topUp.invoiceID, on: database),
                      existing.stripeDeposit?.topUpId == topUp.id else { throw error }
            }
        }
        guard let invoice = try await Rechnung.find(topUp.invoiceID, on: database),
              invoice.stripeDeposit?.topUpId == topUp.id else {
            throw Abort(.conflict, reason: "Top-up invoice does not match its credit.")
        }
        // Persist the permanent applied marker AND email outbox state before releasing the team slot.
        try await set(topUp.id, ["creditedAt": pending.creditedAt, "balanceBefore": pending.before,
            "balanceAfter": pending.after, "nextAttemptAt": Date(), "lastError": Null()])
        _ = try await collection(Team.schema).stripeUpdate(where: ["_id": try Self.uuid(topUp.teamID),
            "pendingStripeCredit.topUpID": topUp.id],
            to: ["$unset": ["pendingStripeCredit": 1], "$inc": ["stripeCreditVersion": 1]]).get()
    }

    static func balance(in document: Document) throws -> Double {
        struct Value: Decodable { let balance: Double? }
        let value = try BSONDecoder().decode(Value.self, from: document).balance ?? 0
        guard value.isFinite else { throw Abort(.conflict, reason: "Team balance is invalid.") }
        return value
    }
}

/// Keeps the existing controllers' +/- arithmetic while preventing a stale model save from
/// overwriting a Stripe credit (or another balance adjustment). Does not change initial balances.
struct TeamBalanceWriteMiddleware: AsyncModelMiddleware {
    func update(model: Team, on db: Database, next: AnyAsyncModelResponder) async throws {
        let input = BalanceInput()
        model.$balance.input(to: input)
        guard input.changed, model.hasLoadedBalance, db is MongoDatabaseRepresentable else {
            try await next.update(model, on: db)
            return
        }
        let delta = (model.balance ?? 0) - (model.loadedBalance ?? 0)
        guard delta.isFinite else { throw Abort(.badRequest, reason: "Balance must be finite.") }
        let teams = try TeamTopUpStore(database: db).collection(Team.schema)
        let id = try TeamTopUpStore.uuid(model.requireID())
        for _ in 0..<20 {
            guard let stored = try await teams.findOne(["_id": id]).get() else { throw Abort(.notFound) }
            let after = try TeamTopUpStore.balance(in: stored) + delta
            guard after.isFinite else { throw Abort(.badRequest, reason: "Balance is out of range.") }
            if try await teams.findOneAndUpdate(where: ["_id": id, "balance": stored["balance"] ?? Null()],
                to: ["$set": ["balance": after]]).stripeExecute().get() != nil {
                try model.$balance.output(from: BalanceOutput(value: after))
                model.loadedBalance = after
                try await next.update(model, on: db)
                return
            }
        }
        throw Abort(.conflict, reason: "Team balance changed concurrently. Retry the operation.")
    }
}

private final class BalanceInput: DatabaseInput {
    var changed = false
    func set(_ value: DatabaseQuery.Value, at key: FieldKey) { changed = true }
}

struct BalanceOutput: DatabaseOutput {
    let value: Double
    var description: String { "Updated team balance" }
    func schema(_ schema: String) -> DatabaseOutput { self }
    func contains(_ key: FieldKey) -> Bool { key == Team.FieldKeys.balance }
    func decodeNil(_ key: FieldKey) throws -> Bool { false }
    func decode<T: Decodable>(_ key: FieldKey, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

struct StripeInvoiceProtectionMiddleware: AsyncModelMiddleware {
    func create(model: Rechnung, on db: Database, next: AnyAsyncModelResponder) async throws {
        if !model.allowsStripeCreation { try model.requireManualEntry() }
        try await next.create(model, on: db)
    }
    func update(model: Rechnung, on db: Database, next: AnyAsyncModelResponder) async throws {
        try model.requireManualEntry()
        if let stored = try await Rechnung.find(model.requireID(), on: db) { try stored.requireManualEntry() }
        try await next.update(model, on: db)
    }
    func delete(model: Rechnung, force: Bool, on db: Database, next: AnyAsyncModelResponder) async throws {
        try model.requireManualEntry()
        if let stored = try await Rechnung.find(model.requireID(), on: db) { try stored.requireManualEntry() }
        try await next.delete(model, force: force, on: db)
    }
}
