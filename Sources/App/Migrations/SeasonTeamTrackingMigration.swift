import Foundation
import Fluent

/// Read-only view of the fields used by deployments created before season
/// bookkeeping moved out of Team.
private final class LegacyTeamSeasonTracking: Model {
    static let schema = Team.schema

    @ID(custom: "id") var id: UUID?
    @OptionalField(key: "league") var leagueID: UUID?
    @OptionalField(key: "cancelled") var cancelled: Int?
    @OptionalField(key: "postponed") var postponed: Int?

    init() {}
}

/// Adds season-scoped cancellation/postponement counters. Legacy Team fields
/// are intentionally left in storage for rollback safety, but are no longer
/// represented or read by the application model.
struct SeasonTeamTrackingMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SeasonTeam.schema)
            .field(SeasonTeam.FieldKeys.cancelled, .int)
            .field(SeasonTeam.FieldKeys.postponed, .int)
            .update()

        let legacyTeams = try await LegacyTeamSeasonTracking.query(on: database).all()
        for legacyTeam in legacyTeams where legacyTeam.cancelled != nil || legacyTeam.postponed != nil {
            let teamID = try legacyTeam.requireID()
            let memberships = try await SeasonTeam.query(on: database)
                .filter(\.$team.$id == teamID)
                .with(\.$season)
                .all()

            var target = memberships.first(where: { $0.season.primary == true })
            if target == nil {
                target = memberships.max { $0.season.details < $1.season.details }
            }

            if target == nil, let leagueID = legacyTeam.leagueID {
                let primarySeason = try await Season.query(on: database)
                    .filter(\.$league.$id == leagueID)
                    .filter(\.$primary == true)
                    .first()
                let latestSeason = try await Season.query(on: database)
                    .filter(\.$league.$id == leagueID)
                    .sort(\.$details, .descending)
                    .first()

                guard let destinationSeason = primarySeason ?? latestSeason else { continue }
                let membership = SeasonTeam(
                    seasonID: try destinationSeason.requireID(),
                    teamID: teamID
                )
                try await membership.save(on: database)
                target = membership
            }

            guard let target else { continue }
            if target.cancelled == nil {
                target.cancelled = legacyTeam.cancelled
            }
            if target.postponed == nil {
                target.postponed = legacyTeam.postponed
            }
            try await target.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(SeasonTeam.schema)
            .deleteField(SeasonTeam.FieldKeys.cancelled)
            .deleteField(SeasonTeam.FieldKeys.postponed)
            .update()
    }
}
