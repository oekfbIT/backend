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
    case ok
    case blocked
}

final class Player: Model, Content, Codable {
    static let schema = "players"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.sid) var sid: String
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.number) var number: String
    @Field(key: FieldKeys.birthday) var birthday: String
    @Parent(key: FieldKeys.teamID) var team: Team
    @Field(key: FieldKeys.nationality) var nationality: String
    @Field(key: FieldKeys.position) var position: String
    @Field(key: FieldKeys.eligibility) var eligibility: PlayerEligibility
    @Field(key: FieldKeys.registerDate) var registerDate: String
    @Field(key: FieldKeys.matchesPlayed) var matchesPlayed: Int
    @Field(key: FieldKeys.goals) var goals: Int

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var sid: FieldKey { "sid" }
       static var name: FieldKey { "name" }
        static var number: FieldKey { "number" }
        static var birthday: FieldKey { "birthday" }
        static var teamID: FieldKey { "teamID" }
        static var nationality: FieldKey { "nationality" }
        static var position: FieldKey { "position" }
        static var eligibility: FieldKey { "eligibility" }
        static var registerDate: FieldKey { "registerDate" }
        static var matchesPlayed: FieldKey { "matchesPlayed" }
        static var goals: FieldKey { "goals" }
    }

    init() {}

    init(id: UUID? = nil, sid: String, name: String, number: String, birthday: String, teamID: UUID, nationality: String, position: String, eligibility: PlayerEligibility, registerDate: String, matchesPlayed: Int, goals: Int) {
        self.id = id
        self.sid = sid
        self.name = name
        self.number = number
        self.birthday = birthday
        self.$team.id = teamID
        self.nationality = nationality
        self.position = position
        self.eligibility = eligibility
        self.registerDate = registerDate
        self.matchesPlayed = matchesPlayed
        self.goals = goals
    }
}

// Player Migration
extension PlayerMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema)
            .field(Player.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Player.FieldKeys.name, .string, .required)
            .field(Player.FieldKeys.number, .string, .required)
            .field(Player.FieldKeys.birthday, .string, .required)
            .field(Player.FieldKeys.teamID, .uuid, .required, .references(Team.schema, Team.FieldKeys.id))
            .field(Player.FieldKeys.nationality, .string, .required)
            .field(Player.FieldKeys.position, .string, .required)
            .field(Player.FieldKeys.eligibility, .string, .required)
            .field(Player.FieldKeys.registerDate, .string, .required)
            .field(Player.FieldKeys.matchesPlayed, .int, .required)
            .field(Player.FieldKeys.goals, .int, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema).delete()
    }
}
