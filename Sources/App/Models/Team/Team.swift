//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
   
import Foundation
import Fluent
import Vapor

struct Trainer: Content, Codable {
    var name: String
    var email: String?
    var image: String?
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
    @OptionalField(key: FieldKeys.foundationYear) var foundationYear: String?
    @OptionalField(key: FieldKeys.membershipSince) var membershipSince: String?
    @Field(key: FieldKeys.averageAge) var averageAge: String
    @OptionalField(key: FieldKeys.coach) var coach: Trainer?
    @OptionalField(key: FieldKeys.captain) var captain: String?
    @Field(key: FieldKeys.trikot) var trikot: Trikot
    @OptionalField(key: FieldKeys.balance) var balance: Double?
    @OptionalField(key: FieldKeys.referCode) var referCode: String?

    // Hidden Values
    @OptionalField(key: FieldKeys.usrpass) var usrpass: String?
    @OptionalField(key: FieldKeys.usremail) var usremail: String?
    @OptionalField(key: FieldKeys.usrtel) var usrtel: String?
    @OptionalField(key: FieldKeys.kaution) var kaution: Double?

    @Children(for: \.$team) var rechnungen: [Rechnung]
    @Children(for: \.$team) var players: [Player]


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
        static var referCode: FieldKey { "referCode" }
        static var usrpass: FieldKey { "usrpass" }
        static var usremail: FieldKey { "usremail" }
        static var usrtel: FieldKey { "usrtel" }
        static var kaution: FieldKey { "kaution" }
    }

    init() {}

    init(id: UUID? = nil, sid: String, userId: UUID?, leagueId: UUID?, leagueCode: String?, points: Int, coverimg: String, logo: String, teamName: String, foundationYear: String?, membershipSince: String?, averageAge: String?, coach: Trainer?, captain: String? = nil, trikot: Trikot, balance: Double? = nil, referCode: String? = String.randomString(length: 6).uppercased(), usremail: String?, usrpass: String?, usrtel: String?, kaution: Double? = nil) {
        self.id = id
        self.sid = sid
        self.$user.id = userId
        self.$league.id = leagueId
        self.leagueCode = leagueCode
        self.points = points
        self.logo = logo
        self.coverimg = coverimg
        self.teamName = teamName
        self.foundationYear = foundationYear
        self.membershipSince = membershipSince
        self.averageAge = averageAge ?? "0"
        self.coach = coach
        self.captain = captain
        self.trikot = trikot
        self.balance = balance
        self.referCode = referCode
        self.usrpass = usrpass
        self.usremail = usremail
        self.usrtel = usrtel
        self.kaution = kaution

    }
    
    struct Public: Codable, Content {
        var id: UUID?
        var sid: String?
        var logo: String?
        var league: UUID?
        var teamName: String
        var foundationYear: String?
        var membershipSince: String?
        var averageAge: String?
        var referCode: String
        var trikot: Trikot?
        var players: [Player.Public]
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            sid: self.sid,
            logo: self.logo,
            league: self.$league.id,
            teamName: self.teamName,
            foundationYear: self.foundationYear,
            membershipSince: self.membershipSince,
            averageAge: self.averageAge,
            referCode: self.referCode ?? String.randomString(length: 6),
            trikot: self.trikot,
            players: self.players.map { $0.asPublic() }
        )
    }
}


extension Team: Mergeable {
    func merge(from other: Team) -> Team {
        var merged = self
        merged.points = other.points
        merged.coverimg = other.coverimg
        merged.logo = other.logo
        merged.$league.id = other.$league.id
        merged.$user.id = other.$user.id
        merged.teamName = other.teamName
        merged.foundationYear = other.foundationYear
        merged.membershipSince = other.membershipSince
        merged.averageAge = other.averageAge
        merged.coach = other.coach
        merged.captain = other.captain
        merged.trikot = other.trikot
        merged.balance = other.balance
        merged.usrpass = other.usrpass
        merged.usremail = other.usremail
        merged.usrtel = other.usrtel
        merged.kaution = other.kaution
        return merged
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
            .field(Team.FieldKeys.usrpass,  .string)
            .field(Team.FieldKeys.usremail,  .string)
            .field(Team.FieldKeys.usrtel,  .string)
            .field(Team.FieldKeys.kaution, .double)

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
    var home: String
    var away: String
}

struct Dress: Codable {
    let image: String
    let color: TrikotColor
}

extension Team {
    func asPublicTeam() -> PublicTeam {
        return PublicTeam(
            id: self.id,
            sid: self.sid,
            leagueCode: self.leagueCode,
            points: self.points,
            logo: self.logo,
            coverimg: self.coverimg,
            teamName: self.teamName,
            foundationYear: self.foundationYear,
            membershipSince: self.membershipSince,
            averageAge: self.averageAge,
            coach: self.coach,
            captain: self.captain,
            trikot: self.trikot,
            stats: nil
        )
    }
}
