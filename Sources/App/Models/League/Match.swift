import Foundation
import Fluent
import Vapor

struct MatchDetails: Codable {
    var gameday: Int
    var date: Date?
    var stadium: UUID?
    var location: String?
}

struct Score: Codable {
    var home: Int
    var away: Int
    
    var displayText: String {
        return "\(home):\(away)"
    }
}

struct PlayerOverview: Codable {
    let id: UUID
    let sid: String
    var name: String
    var number: Int
    var image: String?
    var yellowCard: Int?
    var redYellowCard: Int?
    var redCard: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case sid
        case name
        case number
        case image
        case yellowCard = "yellow_card"
        case redYellowCard = "red_yellow_card"
        case redCard = "red_card"
    }
}

struct Blankett: Codable {
    var name: String?
    var dress: String?
    var logo: String?
    var players: [PlayerOverview]
    var coach: Trainer?
    
    init(name: String?, dress: String?, logo: String?, players: [PlayerOverview]?, coach: Trainer? = nil) {
        self.name = name
        self.dress = dress
        self.logo = logo
        self.players = players ?? []
        self.coach = coach
    }
}


enum GameStatus: String, Codable {
    case pending,
         first,
         second,
         halftime,
         completed,
         abbgebrochen,
         submitted,
         cancelled,
         done
}

final class Match: Model, Content, Codable {
    static let schema = "matches"
    
    // PRE GAME
    @ID(custom: FieldKeys.id) var id: UUID?
    
    // Admin Decided
    @Field(key: FieldKeys.details) var details: MatchDetails
    @OptionalParent(key: FieldKeys.referee) var referee: Referee?
    @OptionalParent(key: FieldKeys.season) var season: Season?
    
    // Admin Decided
    @Parent(key: FieldKeys.homeTeam) var homeTeam: Team
    @Parent(key: FieldKeys.awayTeam) var awayTeam: Team
    
    // User Updated
    @OptionalField(key: FieldKeys.homeBlanket) var homeBlanket: Blankett?
    @OptionalField(key: FieldKeys.awayBlanket) var awayBlanket: Blankett?

    @OptionalField(key: FieldKeys.paid) var paid: Bool?

    // Children
    @Children(for: \.$match) var events: [MatchEvent]
    
    @Field(key: FieldKeys.score) var score: Score
    @Field(key: FieldKeys.status) var status: GameStatus
    
    // MID GAME TO DETERMINE THE TIMER
    @OptionalField(key: FieldKeys.firstHalfStartDate) var firstHalfStartDate: Date?
    @OptionalField(key: FieldKeys.secondHalfStartDate) var secondHalfStartDate: Date?
    @OptionalField(key: FieldKeys.firstHalfEndDate) var firstHalfEndDate: Date?
    @OptionalField(key: FieldKeys.secondHalfEndDate) var secondHalfEndDate: Date?
    
    // POST GAME
    @OptionalField(key: FieldKeys.bericht) var bericht: String?
    

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static var bericht: FieldKey { "bericht" }
        static var paid: FieldKey { "paid" }
        static var homeTeam: FieldKey { "homeTeam" }
        static var awayTeam: FieldKey { "awayTeam" }
        static var season: FieldKey { "season" }
        static var details: FieldKey { "details" }
        static var score: FieldKey { "score" }
        static var status: FieldKey { "status" }
        static var referee: FieldKey { "referee" }
        static var firstHalfStartDate: FieldKey { "firstHalfStartDate" }
        static var secondHalfStartDate: FieldKey { "secondHalfStartDate" }
        static var firstHalfEndDate: FieldKey { "firstHalfEndDate" }
        static var secondHalfEndDate: FieldKey { "secondHalfEndDate" }
        static var homeBlanket: FieldKey { "homeBlanket" }
        static var awayBlanket: FieldKey { "awayBlanket" }
    }

    init() {}

    init(id: UUID? = nil,
         details: MatchDetails,
         homeTeamId: UUID, 
         awayTeamId: UUID,
         homeBlanket: Blankett?,
         awayBlanket: Blankett?,
         score: Score,
         status: GameStatus,
         bericht: String? = nil,
         refereeId: UUID? = nil,
         seasonId: UUID? = nil,
         firstHalfEndDate: Date? = nil,
         secondHalfEndDate: Date? = nil,
         firstHalfStartDate: Date? = nil,
         secondHalfStartDate: Date? = nil,
         paid: Bool? = false) {
        self.id = id
        self.$referee.id = refereeId
        self.$season.id = seasonId
        self.details = details
        self.$homeTeam.id = homeTeamId
        self.$awayTeam.id = awayTeamId
        self.homeBlanket = homeBlanket
        self.awayBlanket = awayBlanket
        self.score = score
        self.status = status
        self.bericht = bericht
        self.firstHalfStartDate = firstHalfStartDate
        self.secondHalfStartDate = secondHalfStartDate
        self.firstHalfEndDate = firstHalfEndDate
        self.secondHalfEndDate = secondHalfEndDate
        self.paid = paid
    }
}

extension Match {
    enum CodingKeys: String, CodingKey {
        case id
        case bericht
        case paid
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case season
        case details
        case score
        case status
        case referee
        case firstHalfStartDate = "first_half_start_date"
        case secondHalfStartDate = "second_half_start_date"
        case firstHalfEndDate = "first_half_end_date"
        case secondHalfEndDate = "second_half_end_date"
        case homeBlanket = "home_blanket"
        case awayBlanket = "away_blanket"
    }
}


// Match Migration
extension MatchMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Match.schema)
            .id()
            .field(Match.FieldKeys.details, .json, .required)
            .field(Match.FieldKeys.homeTeam, .uuid, .required, .references(Team.schema, .id))
            .field(Match.FieldKeys.awayTeam, .uuid, .required, .references(Team.schema, .id))
            .field(Match.FieldKeys.referee, .uuid, .references(Referee.schema, .id))
            .field(Match.FieldKeys.season, .uuid, .references(Season.schema, .id))
            .field(Match.FieldKeys.score, .json, .required)
            .field(Match.FieldKeys.status, .string, .required)
            .field(Match.FieldKeys.firstHalfStartDate, .date)
            .field(Match.FieldKeys.secondHalfStartDate, .date)
            .field(Match.FieldKeys.firstHalfEndDate, .date)
            .field(Match.FieldKeys.secondHalfEndDate, .date)
            .field(Match.FieldKeys.paid, .bool)
            .field(Match.FieldKeys.bericht, .string)
            .field(Match.FieldKeys.homeBlanket, .json)
            .field(Match.FieldKeys.awayBlanket, .json)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Match.schema).delete()
    }
}

extension Match: Mergeable {
    func merge(from other: Match) -> Match {
        var merged = self
        merged.id = other.id ?? self.id
        merged.details = other.details
        merged.$homeTeam.id = other.$homeTeam.id
        merged.$awayTeam.id = other.$awayTeam.id
        merged.score = other.score
        merged.status = other.status
        merged.bericht = other.bericht ?? self.bericht
        merged.$referee.id = other.$referee.id ?? self.$referee.id
        merged.$season.id = other.$season.id ?? self.$season.id
        merged.firstHalfStartDate = other.firstHalfStartDate ?? self.firstHalfStartDate
        merged.secondHalfStartDate = other.secondHalfStartDate ?? self.secondHalfStartDate
        merged.firstHalfEndDate = other.firstHalfEndDate ?? self.firstHalfEndDate
        merged.secondHalfEndDate = other.secondHalfEndDate ?? self.secondHalfEndDate
        merged.paid = other.paid ?? self.paid

        if let homeBlanket = other.homeBlanket {
            merged.homeBlanket = homeBlanket
            print("HOME BLANKET UPDATED")
        }

        if let awayBlanket = other.awayBlanket {
            merged.awayBlanket = awayBlanket
            print("AWAY BLANKET UPDATED")
        }

        return merged
    }
}

