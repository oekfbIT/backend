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
    @OptionalField(key: FieldKeys.altCoach) var altCoach: Trainer?
    @OptionalField(key: FieldKeys.captain) var captain: String?
    @Field(key: FieldKeys.trikot) var trikot: Trikot
    @OptionalField(key: FieldKeys.balance) var balance: Double?
    @OptionalField(key: FieldKeys.referCode) var referCode: String?
    @OptionalField(key: FieldKeys.cancelled) var cancelled: Int?
    @OptionalField(key: FieldKeys.postponed) var postponed: Int?
    @OptionalField(key: FieldKeys.overdraft) var overdraft: Bool?
    @OptionalField(key: FieldKeys.overdraftDate) var overdraftDate: Date?
    // Hidden Values
    @OptionalField(key: FieldKeys.usrpass) var usrpass: String?
    @OptionalField(key: FieldKeys.usremail) var usremail: String?
    @OptionalField(key: FieldKeys.usrtel) var usrtel: String?
    @OptionalField(key: FieldKeys.kaution) var kaution: Double?

    @Children(for: \.$team) var rechnungen: [Rechnung]
    @Children(for: \.$team) var players: [Player]
    
    @OptionalField(key: "nameLower")
    var nameLower: String?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var sid: FieldKey { "sid" }
        static var userId: FieldKey { "user" }
        static var points: FieldKey { "points" }
        static var logo: FieldKey { "logo" }
        static var cancelled: FieldKey { "cancelled" }
        static var postponed: FieldKey { "postponed" }
        static var coverimg: FieldKey { "coverimg" }
        static var leagueId: FieldKey { "league" }
        static var leagueCode: FieldKey { "leagueCode" }
        static var teamName: FieldKey { "teamName" }
        static var foundationYear: FieldKey { "foundationYear" }
        static var membershipSince: FieldKey { "membershipSince" }
        static var averageAge: FieldKey { "averageAge" }
        static var coach: FieldKey { "coach" }
        static var altCoach: FieldKey { "altCoach" }
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
        static var overdraft: FieldKey { "overdraft" }
        static var overdraftDate: FieldKey { "overdraftDate" }
    }

    init() {}

    init(id: UUID? = nil,
         sid: String,
         userId: UUID?,
         leagueId: UUID?,
         leagueCode: String?,
         points: Int,
         coverimg: String,
         logo: String,
         teamName: String,
         foundationYear: String?,
         membershipSince: String?,
         averageAge: String?,
         coach: Trainer?,
         altCoach: Trainer? = nil,
         captain: String? = nil,
         trikot: Trikot,
         balance: Double? = nil,
         referCode: String? = String.randomString(length: 6).uppercased(),
         overdraft: Bool? = false,
         cancelled: Int? = nil,
         postponed: Int? = nil,
         overdraftDate: Date? = nil,
         usremail: String?,
         usrpass: String?,
         usrtel: String?,
         kaution: Double? = nil) {
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
        self.altCoach = altCoach
        self.captain = captain
        self.trikot = trikot
        self.balance = balance
        self.referCode = referCode
        self.cancelled = cancelled
        self.postponed = postponed
        self.overdraft = overdraft
        self.overdraftDate = overdraftDate
        self.usrpass = usrpass
        self.usremail = usremail
        self.usrtel = usrtel
        self.kaution = kaution
        self.teamNameLower = teamName.lowercased()

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
    
    func asPublicTeam() -> PublicTeamShort {
        PublicTeamShort(id: self.id,
                        sid: self.sid,
                        logo: self.logo,
                        points: self.points,
                        teamName: self.teamName)
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
        merged.altCoach = other.altCoach
        merged.captain = other.captain
        merged.cancelled = other.cancelled
        merged.postponed = other.postponed
        merged.trikot = other.trikot
        merged.balance = other.balance
        merged.overdraft = other.overdraft
        merged.overdraftDate = other.overdraftDate
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
            .field(Team.FieldKeys.altCoach, .json)
            .field(Team.FieldKeys.captain, .string)
            .field(Team.FieldKeys.totalMatches, .int)
            .field(Team.FieldKeys.cancelled, .int)
            .field(Team.FieldKeys.postponed, .int)
            .field(Team.FieldKeys.totalGoals, .int)
            .field(Team.FieldKeys.trikot, .json)
            .field(Team.FieldKeys.balance, .double)
            .field(Team.FieldKeys.usrpass,  .string)
            .field(Team.FieldKeys.usremail,  .string)
            .field(Team.FieldKeys.usrtel,  .string)
            .field(Team.FieldKeys.kaution, .double)
            .field(Team.FieldKeys.overdraft, .bool)
            .field(Team.FieldKeys.overdraftDate, .date)
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
            altCoach: self.altCoach,
            captain: self.captain,
            trikot: self.trikot,
            stats: nil
        )
    }
}


// MARK: - Team Extensions
extension Team {
    /// Converts Team to full AppTeam with cached stats
    func toAppTeam(
        league: AppModels.AppLeagueOverview,
        players: [AppModels.AppPlayer],
        req: Request
    ) async throws -> EventLoopFuture<AppModels.AppTeam> {
        let teamID = try requireID()

        let form = try await Team.getRecentForm(
            for: self.id!,
            on: req.db,
            onlyPrimarySeason: true
        )
        return StatsCacheManager.getTeamStats(for: teamID, on: req.db)
            .map { stats in
                AppModels.AppTeam(
                    id: teamID,
                    sid: self.sid ?? "",
                    league: league,
                    points: self.points,
                    logo: self.logo,
                    teamImage: self.coverimg ?? "",
                    name: self.teamName,
                    foundation: self.foundationYear ?? "",
                    membership: self.membershipSince ?? "",
                    coach: self.coach ?? Trainer(name: "Unbekannt"),
                    altCoach: self.altCoach,
                    captain: UUID(uuidString: self.captain ?? "") ?? UUID(),
                    trikot: self.trikot,
                    balance: self.balance,
                    players: players,
                    stats: stats,
                    form: form
                )
            }
    }

    /// Converts Team to overview AppTeamOverview with cached stats
    func toAppTeamOverview(
        league: AppModels.AppLeagueOverview,
        req: Request
    ) throws -> EventLoopFuture<AppModels.AppTeamOverview> {
        let teamID = try requireID()
        
        return StatsCacheManager.getTeamStats(for: teamID, on: req.db)
            .map { stats in
                AppModels.AppTeamOverview(
                    id: teamID,
                    sid: self.sid ?? "",
                    league: league,
                    points: self.points,
                    logo: self.logo,
                    name: self.teamName,
                    stats: stats
                )
            }
    }
}


extension Team {
    static func getRecentForm(
        for teamID: UUID,
        on db: Database,
        onlyPrimarySeason: Bool = false
    ) async throws -> [FormItem] {
        // Start base query
        var query = Match.query(on: db)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                or.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status == .done)

        // 🔹 Restrict to primary season if requested
        if onlyPrimarySeason {
            query = query
                .join(parent: \Match.$season)
                .filter(Season.self, \.$primary == true)
        }

        let matches = try await query.all()

        // Sort manually by date
        let sortedMatches = matches.sorted {
            let d1 = $0.details.date ?? .distantPast
            let d2 = $1.details.date ?? .distantPast
            return d1 > d2
        }

        let recentMatches = Array(sortedMatches.prefix(5))

        return recentMatches.compactMap { match in
            guard let matchID = match.id else { return defaultFromItemBlank }

            let isHome = match.$homeTeam.id == teamID
            let homeScore = match.score.home
            let awayScore = match.score.away

            let result: FormResultItem
            if homeScore == awayScore {
                result = .D
            } else if (isHome && homeScore > awayScore) || (!isHome && awayScore > homeScore) {
                result = .W
            } else {
                result = .L
            }

            return FormItem(result: result,
                            matchID: matchID,
                            gameday: match.details.gameday,
                            score: match.score,
                            home: match.homeBlanket?.name,
                            away: match.awayBlanket?.name,
                            date: match.details.date)
        }
    }
}


private var defaultFromItemBlank: FormItem {
    return FormItem(result: .D, matchID: UUID(), gameday: 1)
}
