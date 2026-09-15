import Fluent
import FluentMongoDriver
import MongoKitten
import Vapor

/// Stable business keys; amounts are always nonnegative EUR cents.
enum FeeKey: String, CaseIterable, Codable {
    case playerRegistration, matchPostponement
    case matchCancellationFirst, matchCancellationSecond, matchCancellationThird
    case overdraft, registrationDeposit, registrationPerGame

    static let cancellationTiers: [FeeKey] = [.matchCancellationFirst, .matchCancellationSecond, .matchCancellationThird]

    static func cancellation(_ count: Int) throws -> FeeKey {
        guard (1...cancellationTiers.count).contains(count) else {
            throw Abort(.badRequest, reason: "Schon 3 Absagen gemacht diese Saison.")
        }
        return cancellationTiers[count - 1]
    }

}

struct AppliedFee: Codable, Equatable {
    let key: FeeKey
    let amountMinor: Int
    let currency: String
    let version: Int
    var euros: Double { Double(amountMinor) / 100 }
}

struct FeeChange: Content {
    let version: Int
    let changedAt: Date
    let changedBy: String
    let previousAmounts: [String: Int]
    let amounts: [String: Int]
}

struct FeeSettings: Content {
    static let schema = "fee_settings"
    static let defaults: [String: Int] = [
        "playerRegistration": 500, "matchPostponement": 5000,
        "matchCancellationFirst": 17000, "matchCancellationSecond": 27000,
        "matchCancellationThird": 37000, "overdraft": 5000,
        "registrationDeposit": 30000, "registrationPerGame": 8000
    ]
    let scope: String
    let currency: String
    let version: Int
    let amounts: [String: Int]
    let updatedAt: Date
    let updatedBy: String
    let history: [FeeChange]

    static func validate(_ amounts: [String: Int]) throws {
        guard Set(amounts.keys) == Set(FeeKey.allCases.map(\.rawValue)),
              amounts.values.allSatisfy({ (0...100_000_000).contains($0) }) else {
            throw Abort(.badRequest, reason: "Alle bekannten Gebühren müssen als ganze Centbeträge zwischen 0 und 100.000.000 angegeben werden.")
        }
    }

    // Only settings validated by FeeService are used to calculate charges.
    func fee(_ key: FeeKey) -> AppliedFee {
        AppliedFee(key: key, amountMinor: amounts[key.rawValue]!, currency: currency, version: version)
    }
}

struct FeeSettingsUpdate: Content {
    let version: Int
    let amounts: [String: Int]
}

/// Public view deliberately excludes administrator identities and history.
struct FeeCatalog: Content {
    let currency: String
    let version: Int
    let amounts: [String: Int]
}

struct FeeService {
    let database: Database

    private var collection: MongoCollection {
        get throws {
            guard let mongo = database as? MongoDatabaseRepresentable else {
                throw Abort(.serviceUnavailable, reason: "Gebühren benötigen MongoDB.")
            }
            return mongo.raw[FeeSettings.schema]
        }
    }

    func seed() async throws {
        let initial = FeeSettings(scope: "global", currency: "EUR", version: 1,
            amounts: FeeSettings.defaults, updatedAt: Date(), updatedBy: "system", history: [])
        var document = try BSONEncoder().encode(initial)
        document["_id"] = "global"
        let reply = try await collection.upsert(["$setOnInsert": document], where: ["_id": "global"]).get()
        guard reply.ok == 1, reply.writeConcernError == nil, (reply.writeErrors ?? []).isEmpty else { throw reply }
    }

    func read() async throws -> FeeSettings {
        guard let settings = try await collection.findOne(["_id": "global"], as: FeeSettings.self).get() else {
            throw Abort(.serviceUnavailable, reason: "Gebühren sind noch nicht eingerichtet.")
        }
        do { try FeeSettings.validate(settings.amounts) }
        catch { throw Abort(.serviceUnavailable, reason: "Gebührenkonfiguration ist ungültig.") }
        guard settings.currency == "EUR", settings.version > 0 else {
            throw Abort(.serviceUnavailable, reason: "Gebührenkonfiguration ist ungültig.")
        }
        return settings
    }

    static func forRequest(_ req: Request) async throws -> FeeSettings {
        let settings = try await FeeService(database: req.db).read()
        if let value = req.headers.first(name: "X-Fee-Version") {
            guard let version = Int(value), version == settings.version else {
                throw Abort(.conflict, reason: "Die Gebühren wurden geändert. Bitte den aktuellen Betrag laden und erneut bestätigen.")
            }
        }
        return settings
    }

    static func load(_ req: Request) -> EventLoopFuture<FeeSettings> {
        req.eventLoop.makeFutureWithTask { try await FeeService.forRequest(req) }
    }

    func update(_ input: FeeSettingsUpdate, by userID: UUID) async throws -> FeeSettings {
        try FeeSettings.validate(input.amounts)
        let previous = try await read()
        guard previous.version == input.version else {
            throw Abort(.conflict, reason: "Gebühren wurden inzwischen geändert. Bitte neu laden und Änderungen erneut prüfen.")
        }
        let now = Date()
        let change = FeeChange(version: input.version + 1, changedAt: now,
            changedBy: userID.uuidString, previousAmounts: previous.amounts, amounts: input.amounts)
        // History and prices change together in one atomic compare-and-swap.
        let fields: Document = ["amounts": try BSONEncoder().encode(input.amounts),
            "version": change.version, "updatedAt": now, "updatedBy": userID.uuidString]
        let reply = try await collection.findOneAndUpdate(where: ["_id": "global", "version": input.version],
            to: ["$set": fields, "$push": ["history": try BSONEncoder().encode(change)] as Document]).execute().get()
        guard reply.ok == 1 else { throw reply }
        guard reply.value != nil else {
            throw Abort(.conflict, reason: "Gebühren wurden inzwischen geändert. Bitte neu laden.")
        }
        return FeeSettings(scope: "global", currency: "EUR", version: change.version,
            amounts: input.amounts, updatedAt: now, updatedBy: userID.uuidString, history: previous.history + [change])
    }
}

struct FeeSettingsMigration: AsyncMigration {
    func prepare(on database: Database) async throws { try await FeeService(database: database).seed() }
    func revert(on database: Database) async throws { /* Preserve configured prices and financial history. */ }
}

extension AdminController {
    func setupFeeRoutes(on admin: RoutesBuilder) {
        admin.get("fees") { req async throws -> FeeSettings in
            try await FeeService(database: req.db).read()
        }
        admin.patch("fees") { req async throws -> FeeSettings in
            let user = try req.auth.require(User.self)
            return try await FeeService(database: req.db).update(req.content.decode(FeeSettingsUpdate.self), by: user.requireID())
        }
        admin.get("fees", "history") { req async throws -> [FeeChange] in
            try await FeeService(database: req.db).read().history.reversed()
        }
    }
}

extension AppController {
    func setupFeeRoutes(on route: RoutesBuilder) {
        route.get("fees") { req async throws -> FeeCatalog in
            let settings = try await FeeService(database: req.db).read()
            return FeeCatalog(currency: settings.currency, version: settings.version, amounts: settings.amounts)
        }
    }
}
