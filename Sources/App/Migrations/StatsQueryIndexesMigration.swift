import Fluent
import FluentMongoDriver
import MongoKitten

/// Online indexes for the match and event lookups used by live player/team
/// pages. MongoDB builds these in the background on the managed cluster, and
/// the named operations are safe to repeat when a deployment restarts.
struct StatsQueryIndexesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let mongo = database as? MongoDatabaseRepresentable else { return }

        let matches = mongo.raw[Match.schema]
        try await createIndex(
            "matches_home_blanket_player_id",
            fields: [("homeBlanket.players.id", 1)],
            on: matches
        )
        try await createIndex(
            "matches_away_blanket_player_id",
            fields: [("awayBlanket.players.id", 1)],
            on: matches
        )
        try await createIndex(
            "matches_home_team_status",
            fields: [("homeTeam", 1), ("status", 1)],
            on: matches
        )
        try await createIndex(
            "matches_away_team_status",
            fields: [("awayTeam", 1), ("status", 1)],
            on: matches
        )
        try await createIndex(
            "matches_season",
            fields: [("season", 1)],
            on: matches
        )
        try await createIndex(
            "matches_season_date",
            fields: [("season", 1), ("details.date", 1)],
            on: matches
        )

        let events = mongo.raw[MatchEvent.schema]
        try await createIndex(
            "match_events_player_id",
            fields: [("playerId", 1)],
            on: events
        )
        try await createIndex(
            "match_events_match_type",
            fields: [("match", 1), ("type", 1)],
            on: events
        )
    }

    func revert(on database: Database) async throws {
        // Deliberately forward-only: these indexes are safe performance
        // improvements and dropping them during a rollback could reintroduce
        // the production outage while live requests are running.
    }

    private func createIndex(
        _ name: String,
        fields: [(String, Int)],
        on collection: MongoCollection
    ) async throws {
        var keys = Document()
        for (field, order) in fields {
            keys[field] = order
        }
        try await collection.createIndex(named: name, keys: keys).get()
    }
}
