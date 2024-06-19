import Vapor
import Fluent

enum PlayerEligibility: String, Codable {
    case Spielberechtigt = "Spielberechtigt"
    case Gesperrt = "Gesperrt"
}

final class Player: Model, Content, Codable {
    static let schema = "players"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.sid) var sid: String
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalField(key: FieldKeys.team_oeid) var team_oeid: String?
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.number) var number: String
    @Field(key: FieldKeys.birthday) var birthday: String
    @OptionalParent(key: FieldKeys.teamID) var team: Team?
    @Field(key: FieldKeys.nationality) var nationality: String
    @Field(key: FieldKeys.position) var position: String
    @Field(key: FieldKeys.eligibility) var eligibility: PlayerEligibility
    @Field(key: FieldKeys.registerDate) var registerDate: String
    @OptionalField(key: FieldKeys.identification) var identification: String?
    @OptionalField(key: FieldKeys.status) var status: Bool?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var sid: FieldKey { "sid" }
        static var image: FieldKey { "image" }
        static var team_oeid: FieldKey { "team_oeid" }
        static var name: FieldKey { "name" }
        static var number: FieldKey { "number" }
        static var birthday: FieldKey { "birthday" }
        static var teamID: FieldKey { "teamID" }
        static var nationality: FieldKey { "nationality" }
        static var position: FieldKey { "position" }
        static var eligibility: FieldKey { "eligibility" }
        static var registerDate: FieldKey { "registerDate" }
        static var identification: FieldKey { "identification" }
        static var status: FieldKey { "status" }
    }

    init() {}

    init(id: UUID? = nil, sid: String, image: String?, team_oeid: String?, name: String, number: String, birthday: String, teamID: UUID?, nationality: String, position: String, eligibility: PlayerEligibility, registerDate: String, identification: String?, status: Bool?) {
        self.id = id
        self.sid = sid
        self.image = image
        self.team_oeid = team_oeid
        self.name = name
        self.number = number
        self.birthday = birthday
        self.$team.id = teamID
        self.nationality = nationality
        self.position = position
        self.eligibility = eligibility
        self.registerDate = registerDate
        self.identification = identification
        self.status = status
    }
}
// Player Migration
extension PlayerMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema)
            .field(Player.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Player.FieldKeys.name, .string, .required)
            .field(Player.FieldKeys.image, .string)
            .field(Player.FieldKeys.team_oeid, .string)
            .field(Player.FieldKeys.number, .string, .required)
            .field(Player.FieldKeys.birthday, .string, .required)
            .field(Player.FieldKeys.teamID, .uuid, .required, .references(Team.schema, Team.FieldKeys.id))
            .field(Player.FieldKeys.nationality, .string, .required)
            .field(Player.FieldKeys.position, .string)
            .field(Player.FieldKeys.eligibility, .string, .required)
            .field(Player.FieldKeys.registerDate, .string)
            .field(Player.FieldKeys.identification, .string)
            .field(Player.FieldKeys.status, .bool)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema).delete()
    }
}


extension Player {
    struct Public: Codable, Content {
        var id: UUID?
        var sid: String
        var image: String?
        var team_oeid: String?
        var name: String
        var number: String
        var birthday: String
        var team: Team?
        var nationality: String
        var position: String
        var eligibility: PlayerEligibility
        var registerDate: String
        var status: Bool?
    }
    
    func asPublic() -> Public {
        return Public(
            id: self.id,
            sid: self.sid,
            image: self.image,
            team_oeid: self.team_oeid,
            name: self.name,
            number: self.number,
            birthday: self.birthday,
            team: self.team,
            nationality: self.nationality,
            position: self.position,
            eligibility: self.eligibility,
            registerDate: self.registerDate,
            status: self.status
        )
    }
}
