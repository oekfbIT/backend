import Foundation
import Fluent
import Vapor

enum RechnungStatus: String, Codable {
    case offen, bezahlt
}

final class Rechnung: Model, Content, Codable {
    static let schema = "rechnungen"

    @ID(custom: .id) var id: UUID?
    @Parent(key: FieldKeys.team) var team: Team
    @Field(key: FieldKeys.status) var status: RechnungStatus
    @Field(key: FieldKeys.teamName) var teamName: String
    @Field(key: FieldKeys.number) var number: String
    @Field(key: FieldKeys.summ) var summ: Double
    @Field(key: FieldKeys.kennzeichen) var kennzeichen: String
    @Field(key: FieldKeys.dueDate) var dueDate: String?
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var team: FieldKey { "team_id" }
        static var status: FieldKey { "status" }
        static var teamName: FieldKey { "teamName" }
        static var number: FieldKey { "number" }
        static var summ: FieldKey { "summ" }
        static var kennzeichen: FieldKey { "kennzeichen" }
        static var dueDate: FieldKey { "due_date" }
        static var created: FieldKey { "created" }
    }

    init() {}

    init(
        id: UUID? = nil,
        team: Team.IDValue,
        teamName: String,
        status: RechnungStatus = .offen,
        number: String,
        summ: Double,
        kennzeichen: String,
        created: Date? = nil
    ) {
        self.id = id
        self.$team.id = team
        self.teamName = teamName
        self.status = status
        self.number = number
        self.summ = summ
        self.kennzeichen = kennzeichen
        self.created = created ?? Date() // Set the created date to the current date if not provided
        
        // Generate due date based on the created date
        let calendar = Calendar.current
        if let dueDate = calendar.date(byAdding: .weekOfYear, value: 2, to: self.created!) {
            self.dueDate = DateFormatter.localizedString(from: dueDate, dateStyle: .short, timeStyle: .none)
        }
    }

    func generateDueDate() {
        if let createdDate = created {
            let calendar = Calendar.current
            if let dueDate = calendar.date(byAdding: .weekOfYear, value: 2, to: createdDate) {
                self.dueDate = DateFormatter.localizedString(from: dueDate, dateStyle: .short, timeStyle: .none)
            }
        }
    }

    func didCreate(on database: Database) -> EventLoopFuture<Void> {
        generateDueDate()
        return self.update(on: database)
    }
}

extension Rechnung: Mergeable {
    func merge(from other: Rechnung) -> Rechnung {
        var merged = self
        merged.id = other.id
        merged.$team.id = other.$team.id
        merged.status = other.status
        merged.teamName = other.teamName
        merged.number = other.number
        merged.summ = other.summ
        merged.kennzeichen = other.kennzeichen
        merged.dueDate = other.dueDate
        merged.created = other.created
        return merged
    }
}

// Migration
extension RechnungMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Rechnung.schema)
            .id()
            .field(Rechnung.FieldKeys.team, .uuid, .required, .references(Team.schema, .id))
            .field(Rechnung.FieldKeys.status, .string, .required)
            .field(Rechnung.FieldKeys.teamName, .string, .required)
            .field(Rechnung.FieldKeys.number, .string, .required)
            .field(Rechnung.FieldKeys.summ, .double, .required)
            .field(Rechnung.FieldKeys.kennzeichen, .string, .required)
            .field(Rechnung.FieldKeys.dueDate, .string)
            .field(Rechnung.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Rechnung.schema).delete()
    }
}
