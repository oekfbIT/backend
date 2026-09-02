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

    struct FieldKeys {
        static let season: FieldKey = "season"
        static let team: FieldKey = "team"
        static let hasPaidSeasonFee: FieldKey = "hasPaidSeasonFee"
        static let seasonFee: FieldKey = "seasonFee"
    }

    init() {}

    init(
        id: UUID? = nil,
        seasonID: UUID,
        teamID: UUID,
        hasPaidSeasonFee: Bool? = nil,
        seasonFee: Double? = nil
    ) {
        self.id = id
        self.$season.id = seasonID
        self.$team.id = teamID
        self.hasPaidSeasonFee = hasPaidSeasonFee
        self.seasonFee = seasonFee
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
