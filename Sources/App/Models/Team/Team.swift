//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
   
import Foundation
import Fluent
import Vapor

struct Trainer: Codable {
    let name: String
    let imageURL: String?
}

final class Team: Model, Content {
    static let schema = "teams"

    @ID(custom: FieldKeys.id) var id: UUID?
    @ID(custom: FieldKeys.sid) var sid: String?
    @OptionalParent(key: FieldKeys.userId) var user: User?
    @OptionalParent(key: FieldKeys.leagueId) var league: League?
    @OptionalField(key: FieldKeys.leagueCode) var leagueCode: String?
    @Field(key: FieldKeys.points) var points: Int
    @Field(key: FieldKeys.logo) var logo: String
    @OptionalField(key: FieldKeys.coverimg) var coverimg: String?
    @Field(key: FieldKeys.teamName) var teamName: String
    @Field(key: FieldKeys.foundationYear) var foundationYear: String
    @Field(key: FieldKeys.membershipSince) var membershipSince: String
    @Field(key: FieldKeys.averageAge) var averageAge: String
    @OptionalField(key: FieldKeys.coach) var coach: Trainer?
    @OptionalField(key: FieldKeys.captain) var captain: String?
    @Children(for: \.$team) var players: [Player]
    @Field(key: FieldKeys.trikot) var trikot: Trikot
    @OptionalField(key: FieldKeys.balance) var balance: Double?
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var sid: FieldKey { "sid" }
        static var userId: FieldKey { "user" }
        static var points: FieldKey { "points" }
        static var logo: FieldKey { "logo" }
        static var coverimg: FieldKey { "coverimg" }
        static var leagueId: FieldKey { "league" }
        static var leagueCode: FieldKey { "leagueCode" }
        static var teamName: FieldKey { "teamName" }
        static var foundationYear: FieldKey { "foundationYear" }
        static var membershipSince: FieldKey { "membershipSince" }
        static var averageAge: FieldKey { "averageAge" }
        static var coach: FieldKey { "coach" }
        static var captain: FieldKey { "captain" }
        static var totalMatches: FieldKey { "totalMatches" }
        static var totalGoals: FieldKey { "totalGoals" }
        static var trikot: FieldKey { "trikot" }
        static var balance: FieldKey { "balance" }
    }

    init() {}

    init(id: UUID? = nil, sid: String, userId: UUID?, leagueId: UUID?, leagueCode: String?, points: Int, coverimg: String, logo: String, teamName: String, foundationYear: String, membershipSince: String, averageAge: String, coach: Trainer? = nil, captain: String? = nil, trikot: Trikot, balance: Double? = nil) {
        self.id = id
        self.sid = sid
        self.$user.id = UUID(uuidString: "96D72F77-5EC8-4802-A8BA-E9928E362E2A")
        self.$league.id = leagueId
        self.leagueCode = leagueCode
        self.points = points
        self.logo = logo
        self.coverimg = coverimg
        self.teamName = teamName
        self.foundationYear = foundationYear
        self.membershipSince = membershipSince
        self.averageAge = averageAge
        self.coach = coach
        self.captain = captain
        self.trikot = trikot
        self.balance = balance
    }
    
    struct Public: Codable, Content {
        var id: UUID?
        var sid: String?
        var teamName: String
        var foundationYear: String
        var membershipSince: String
        var averageAge: String
        var players: [Player.Public]
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            sid: self.sid,
            teamName: self.teamName,
            foundationYear: self.foundationYear,
            membershipSince: self.membershipSince,
            averageAge: self.averageAge,
            players: []
        )
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
            .field(Team.FieldKeys.coverimg, .string)
            .field(Team.FieldKeys.teamName, .string)
            .field(Team.FieldKeys.foundationYear, .string)
            .field(Team.FieldKeys.membershipSince, .datetime)
            .field(Team.FieldKeys.averageAge, .string)
            .field(Team.FieldKeys.coach, .json)
            .field(Team.FieldKeys.captain, .string)
            .field(Team.FieldKeys.totalMatches, .int)
            .field(Team.FieldKeys.totalGoals, .int)
            .field(Team.FieldKeys.trikot, .json)
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
