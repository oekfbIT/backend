//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Foundation
import Fluent
import Vapor

final class Team: Model, Content {
    static let schema = "teams"

    @ID(custom: "id") var id: UUID?
    @OptionalParent(key: "user") var user: User?
    @Parent(key: "league") var league: League
    @Field(key: "points") var points: Int
    @Field(key: "logo") var logo: String
    @Field(key: "teamName") var teamName: String
    @Field(key: "foundationYear") var foundationYear: String
    @Field(key: "membershipSince") var membershipSince: String
    @Field(key: "averageAge") var averageAge: String
    @OptionalField(key: "coachName") var coachName: String?
    @OptionalField(key: "captain") var captain: String?
    @Children(for: \.$team) var players: [Player]
    @Field(key: "trikot") var trikot: Trikot
    @OptionalField(key: "balance") var balance: Double?
    
    struct FieldKeys {
          static var id: FieldKey { "id" }
          static var userId: FieldKey { "user" }
          static var points: FieldKey { "points" }
          static var logo: FieldKey { "logo" }
          static var leagueId: FieldKey { "league" }
          static var teamName: FieldKey { "teamName" }
          static var foundationYear: FieldKey { "foundationYear" }
          static var membershipSince: FieldKey { "membershipSince" }
          static var averageAge: FieldKey { "averageAge" }
          static var coachName: FieldKey { "coachName" }
          static var captain: FieldKey { "captain" }
          static var totalMatches: FieldKey { "totalMatches" }
          static var totalGoals: FieldKey { "totalGoals" }
          static var goalsPerMatch: FieldKey { "goalsPerMatch" }
          static var balance: FieldKey { "balance" }
    
      }
    
    init() {}
    
    init(id: UUID? = nil, userId: UUID?, leagueId: UUID, points: Int, logo: String, teamName: String, foundationYear: String, membershipSince: String, averageAge: String, coachName: String? = nil, captain: String? = nil, trikot: Trikot, balance: Double? = nil) {
        self.id = id
        self.$user.id = UUID(uuidString: "F540887F-1377-4B6D-9681-2D103B1CEF57")
        self.$league.id = leagueId
        self.points = points
        self.logo = logo
        self.teamName = teamName
        self.foundationYear = foundationYear
        self.membershipSince = membershipSince
        self.averageAge = averageAge
        self.coachName = coachName
        self.captain = captain
        self.trikot = trikot
        self.balance = balance
    }
}


// Team Migration
extension TeamMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Team.schema)
            .field(Team.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Team.FieldKeys.userId, .uuid, .references(User.schema, User.FieldKeys.id))
            .field(Team.FieldKeys.leagueId, .uuid, .references(League.schema, League.FieldKeys.id))
            .field(Team.FieldKeys.points, .int)
            .field(Team.FieldKeys.logo, .string)
            .field(Team.FieldKeys.teamName, .string)
            .field(Team.FieldKeys.foundationYear, .string)
            .field(Team.FieldKeys.membershipSince, .datetime)
            .field(Team.FieldKeys.averageAge, .string)
            .field(Team.FieldKeys.coachName, .string)
            .field(Team.FieldKeys.captain, .string)
            .field(Team.FieldKeys.totalMatches, .int)
            .field(Team.FieldKeys.totalGoals, .int)
            .field(Team.FieldKeys.goalsPerMatch, .double)
            .field(Team.FieldKeys.balance, .double)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Team.schema).delete()
    }
}

enum TeamStatus: String, Codable {
    case active, frozen
}

struct Trikot: Codable {
    let home: Dress
    let away: Dress
}

struct Dress: Codable {
    let image: String
    let color: TrikotColor
}
