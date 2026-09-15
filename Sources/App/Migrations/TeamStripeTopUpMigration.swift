import Fluent
import FluentMongoDriver
import MongoKitten

struct TeamStripeTopUpMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let mongo = database as? MongoDatabaseRepresentable else { return }
        // Mongo _id already enforces uniqueness for deterministic top-ups, invoices and webhook events.
        try await mongo.raw[TeamTopUp.schema].createIndex(named: "topup_recovery",
            keys: ["needsReview": 1, "nextAttemptAt": 1, "leaseUntil": 1]).get()
        try await mongo.raw["team_stripe_events"].createIndex(named: "pending_events",
            keys: ["pending": 1, "receivedAt": 1]).get()
        try await mongo.raw[Rechnung.schema].createIndex(named: "team_payment_history",
            keys: ["teamID": 1, "paymentSource": 1, "created": -1]).get()
    }
    func revert(on database: Database) async throws {
        // Preserve payment records and indexes when application code is rolled back.
    }
}
