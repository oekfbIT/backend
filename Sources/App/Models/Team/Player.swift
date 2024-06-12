//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Foundation
import Fluent
import Vapor

enum PlayerEligibility: String, Codable {
    case Spielberechtigt
    case Gesperrt
}

final class Player: Model, Content, Codable {
    static let schema = "players"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.sid) var sid: String
    @Field(key: FieldKeys.image) var image: String
    @Field(key: FieldKeys.team_oeid) var team_oeid: String
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.number) var number: String
    @Field(key: FieldKeys.birthday) var birthday: String
    @OptionalParent(key: FieldKeys.teamID) var team: Team?
    @Field(key: FieldKeys.nationality) var nationality: String
    @Field(key: FieldKeys.position) var position: String
    @Field(key: FieldKeys.eligibility) var eligibility: PlayerEligibility
    @Field(key: FieldKeys.registerDate) var registerDate: String

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
    }

    init() {}

    init(id: UUID? = nil, sid: String, image: String, team_oeid: String, name: String, number: String, birthday: String, teamID: UUID?, nationality: String, position: String, eligibility: PlayerEligibility, registerDate: String) {
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
    }
}

// Player Migration
extension PlayerMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema)
            .field(Player.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Player.FieldKeys.name, .string, .required)
            .field(Player.FieldKeys.image, .string, .required)
            .field(Player.FieldKeys.team_oeid, .string, .required)
            .field(Player.FieldKeys.number, .string, .required)
            .field(Player.FieldKeys.birthday, .string, .required)
            .field(Player.FieldKeys.teamID, .uuid, .required, .references(Team.schema, Team.FieldKeys.id))
            .field(Player.FieldKeys.nationality, .string, .required)
            .field(Player.FieldKeys.position, .string, .required)
            .field(Player.FieldKeys.eligibility, .string, .required)
            .field(Player.FieldKeys.registerDate, .string, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema).delete()
    }
}
