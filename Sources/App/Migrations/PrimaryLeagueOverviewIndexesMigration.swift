import Fluent
import FluentMongoDriver
import MongoKitten

/// Supports the primary-season lookup that powers the all-leagues screen.
struct PrimaryLeagueOverviewIndexesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let mongo = database as? MongoDatabaseRepresentable else { return }

        try await mongo.raw[Season.schema].createIndex(
            named: "seasons_primary_league",
            keys: ["primary": 1, "league": 1]
        ).get()
    }

    func revert(on database: Database) async throws {
        // Forward-only: this is an additive performance index.
    }
}
