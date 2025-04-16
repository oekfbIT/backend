
import Foundation
import Fluent
import Vapor


final class MatchAchivement: Model, Content, Codable {
    static let schema = "match_events"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Parent(key: FieldKeys.team) var team: Team
    @Field(key: FieldKeys.title) var title: String

    enum FieldKeys {
        static let id: FieldKey = "id"
        static let team: FieldKey = "team"
        static let title: FieldKey = "title"
}

    init() {}

    init(id: UUID? = nil,team: UUID, minute: Int, title: String) {
        self.id = id
        self.$team.id = team
        self.title = title
    }
}

extension MatchAchivement: Mergeable {
    func merge(from other: MatchAchivement) -> MatchAchivement {
        var merged = self
        merged.$team.id = other.$team.id
        merged.team = other.team
        merged.title = other.title
        return merged
    }
}

// MatchEvent Migration
extension MatchAchivementMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchAchivement.schema)
            .field(MatchAchivement.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(MatchAchivement.FieldKeys.team, .uuid, .required, .references(Team.schema, Team.FieldKeys.id))
            .field(MatchAchivement.FieldKeys.title, .string, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchAchivement.schema).delete()
    }
}
