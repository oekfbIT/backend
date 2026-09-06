import Fluent
import Vapor

/// Admin-only bookkeeping for a team's participation in a season.
/// Match scheduling and game state intentionally do not depend on this model.
final class SeasonTeam: Model, Content {
    static let schema = "season_teams"

    @ID(key: .id) var id: UUID?
    @Parent(key: FieldKeys.season) var season: Season
    @Parent(key: FieldKeys.team) var team: Team
    @OptionalField(key: FieldKeys.hasPaidSeasonFee) var hasPaidSeasonFee: Bool?
    @OptionalField(key: FieldKeys.seasonFee) var seasonFee: Double?
    @OptionalField(key: FieldKeys.cancelled) var cancelled: Int?
    @OptionalField(key: FieldKeys.postponed) var postponed: Int?

    struct FieldKeys {
        static let season: FieldKey = "season"
        static let team: FieldKey = "team"
        static let hasPaidSeasonFee: FieldKey = "hasPaidSeasonFee"
        static let seasonFee: FieldKey = "seasonFee"
        static let cancelled: FieldKey = "cancelled"
        static let postponed: FieldKey = "postponed"
    }

    init() {}

    init(
        id: UUID? = nil,
        seasonID: UUID,
        teamID: UUID,
        hasPaidSeasonFee: Bool? = nil,
        seasonFee: Double? = nil,
        cancelled: Int? = nil,
        postponed: Int? = nil
    ) {
        self.id = id
        self.$season.id = seasonID
        self.$team.id = teamID
        self.hasPaidSeasonFee = hasPaidSeasonFee
        self.seasonFee = seasonFee
        self.cancelled = cancelled
        self.postponed = postponed
    }
}

extension SeasonTeam {
    /// Returns the season-specific team record for a match, creating it for
    /// legacy seasons that predate explicit SeasonTeam membership.
    static func participation(
        for match: Match,
        teamID: UUID,
        on database: Database
    ) async throws -> SeasonTeam {
        guard let seasonID = match.$season.id else {
            throw Abort(.unprocessableEntity, reason: "Match must belong to a season before season bookkeeping can be updated.")
        }

        if let existing = try await SeasonTeam.query(on: database)
            .filter(\.$season.$id == seasonID)
            .filter(\.$team.$id == teamID)
            .first() {
            return existing
        }

        let participation = SeasonTeam(seasonID: seasonID, teamID: teamID)
        do {
            try await participation.save(on: database)
            return participation
        } catch {
            // A concurrent request may have inserted the unique season/team
            // pair between the lookup and save. Resolve that race by reading it.
            if let existing = try await SeasonTeam.query(on: database)
                .filter(\.$season.$id == seasonID)
                .filter(\.$team.$id == teamID)
                .first() {
                return existing
            }
            throw error
        }
    }

    /// Applies the season cancellation limit and persists the new count.
    @discardableResult
    static func registerCancellation(
        for match: Match,
        teamID: UUID,
        on database: Database
    ) async throws -> Int {
        let participation = try await participation(for: match, teamID: teamID, on: database)
        let current = participation.cancelled ?? 0
        guard current < 3 else {
            throw Abort(.badRequest, reason: "Schon 3 Absagen gemacht diese Saison.")
        }

        let updated = current + 1
        participation.cancelled = updated
        try await participation.save(on: database)
        return updated
    }

    /// Counts an approved postponement against the requesting team in the
    /// season containing the affected match.
    @discardableResult
    static func registerPostponement(
        for match: Match,
        teamID: UUID,
        on database: Database
    ) async throws -> Int {
        let participation = try await participation(for: match, teamID: teamID, on: database)
        let updated = (participation.postponed ?? 0) + 1
        participation.postponed = updated
        try await participation.save(on: database)
        return updated
    }
}

struct SeasonTeamMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(SeasonTeam.schema)
            .id()
            .field(SeasonTeam.FieldKeys.season, .uuid, .required, .references(Season.schema, .id))
            .field(SeasonTeam.FieldKeys.team, .uuid, .required, .references(Team.schema, .id))
            .field(SeasonTeam.FieldKeys.hasPaidSeasonFee, .bool)
            .field(SeasonTeam.FieldKeys.seasonFee, .double)
            .unique(on: SeasonTeam.FieldKeys.season, SeasonTeam.FieldKeys.team)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(SeasonTeam.schema).delete()
    }
}
