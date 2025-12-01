import Vapor
import Fluent

enum PlayerEligibility: String, Codable {
    case Spielberechtigt = "Spielberechtigt"
    case Gesperrt = "Gesperrt"
    case Warten = "Warten"
}

struct Profile: Codable, Content {
    let name: String
    let number: String
    let birthday: String
    let nationality: String
    let position: String
    let eligibility: PlayerEligibility
    let registerDate: String
    let captain: Bool
}

final class Player: Model, Content, Codable {
    static let schema = "players"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.sid) var sid: String
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalParent(key: FieldKeys.teamID) var team: Team?
    @OptionalField(key: FieldKeys.team_oeid) var team_oeid: String?
    @OptionalField(key: FieldKeys.email) var email: String?
    @OptionalField(key: FieldKeys.balance) var balance: Double?

    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.number) var number: String
    @Field(key: FieldKeys.birthday) var birthday: String
    @Field(key: FieldKeys.nationality) var nationality: String
    @Field(key: FieldKeys.position) var position: String
    @Field(key: FieldKeys.eligibility) var eligibility: PlayerEligibility
    @Field(key: FieldKeys.registerDate) var registerDate: String
    
    @OptionalField(key: FieldKeys.identification) var identification: String?
    @OptionalField(key: FieldKeys.status) var status: Bool?
    @OptionalField(key: FieldKeys.isCaptain) var isCaptain: Bool?
    @OptionalField(key: FieldKeys.bank) var bank: Bool?
    @OptionalField(key: FieldKeys.transferred) var transferred: Bool?
    @OptionalField(key: FieldKeys.blockdate) var blockdate: Date?

    @Children(for: \.$player) var events: [MatchEvent]

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var sid: FieldKey { "sid" }
        static var image: FieldKey { "image" }
        static var email: FieldKey { "email" }
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
        static var isCaptain: FieldKey { "isCaptain" }
        static var bank: FieldKey { "bank" }
        static var transferred: FieldKey { "transferred" }
        static var blockdate: FieldKey { "blockdate" }
        static var balance: FieldKey { "balance" }
    }

    init() {}

    init(id: UUID? = nil, sid: String, image: String?, team_oeid: String?, email: String?, balance: Double? = nil, name: String, number: String, birthday: String, teamID: UUID?, nationality: String, position: String, eligibility: PlayerEligibility, registerDate: String, identification: String?, status: Bool?, isCaptain: Bool? = false, bank: Bool? = true, blockdate: Date? = nil ) {
        self.id = id
        self.sid = sid
        self.image = image
        self.email = email
        self.balance = balance
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
        self.isCaptain = isCaptain
        self.bank = bank
        self.blockdate = blockdate
    }
}

// Player Migration (fixed version)
extension PlayerMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Player.schema)
            .field(Player.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Player.FieldKeys.name, .string, .required)
            .field(Player.FieldKeys.image, .string)
            .field(Player.FieldKeys.team_oeid, .string)
            .field(Player.FieldKeys.email, .string)
            .field(Player.FieldKeys.balance, .double)
            .field(Player.FieldKeys.number, .string, .required)
            .field(Player.FieldKeys.birthday, .string, .required)
            .field(Player.FieldKeys.teamID, .uuid, .required, .references(Team.schema, Team.FieldKeys.id))
            .field(Player.FieldKeys.nationality, .string, .required)
            .field(Player.FieldKeys.position, .string)
            .field(Player.FieldKeys.eligibility, .string, .required)
            .field(Player.FieldKeys.registerDate, .string)
            .field(Player.FieldKeys.identification, .string)
            .field(Player.FieldKeys.status, .bool)
            .field(Player.FieldKeys.isCaptain, .bool)
            .field(Player.FieldKeys.bank, .bool)
            .field(Player.FieldKeys.blockdate, .date)
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
        var isCaptain: Bool?
        var bank: Bool?
        var blockdate: Date?
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
            status: self.status,
            isCaptain: self.isCaptain,
            bank: self.bank,
            blockdate: self.blockdate
        )
    }
}

extension Player: Mergeable {
    func merge(from other: Player) -> Player {
        var merged = self
        merged.id = other.id
        merged.sid = other.sid
        merged.name = other.name
        merged.image = other.image
        merged.email = other.email
        merged.balance = other.balance
        merged.number = other.number
        merged.birthday = other.birthday
        merged.$team.id = other.$team.id
        merged.nationality = other.nationality
        merged.position = other.position
        merged.eligibility = other.eligibility
        merged.registerDate = other.registerDate
        merged.identification = other.identification
        merged.status = other.status
        merged.isCaptain = other.isCaptain
        merged.bank = other.bank
        merged.blockdate = other.blockdate
        return merged
    }
}

extension Player { 
    /// Asynchronously computes stats from the database.
    func getStats(on db: Database) -> EventLoopFuture<PlayerStats> {
        return self.$events.query(on: db).all().map { events in
            Self.computeStats(from: events)
        }
    }

    /// Computes stats directly from an already-loaded `events` array (no DB hit).
    func getStatsFromLoadedEvents() -> PlayerStats {
        return Self.computeStats(from: self.events)
    }

    /// Internal reusable logic for both cases
    private static func computeStats(from events: [MatchEvent]) -> PlayerStats {
        var stats = PlayerStats(
            matchesPlayed: 0,
            goalsScored: 0,
            redCards: 0,
            yellowCards: 0,
            yellowRedCrd: 0
        )

        var matchSet = Set<UUID>()

        for event in events {
            matchSet.insert(event.$match.id)

            switch event.type {
            case .goal:
                stats.goalsScored += 1
            case .redCard:
                stats.redCards += 1
            case .yellowCard:
                stats.yellowCards += 1
            case .yellowRedCard:
                stats.yellowRedCrd += 1
            default:
                break
            }
        }

        stats.matchesPlayed = matchSet.count
        return stats
    }
}

// MARK: - Player → App models

extension Player {
    func toAppPlayer(
        team: AppModels.AppTeamOverview,
        events: [AppModels.AppMatchEvent] = [],
        nextMatches: [AppModels.NextMatch] = [],
        req: Request
    ) async throws -> AppModels.AppPlayer {

        // Use cached stats
        let stats = try await StatsCacheManager
            .getPlayerStats(for: try self.id ?? UUID(), on: req.db)
            .get()

        return AppModels.AppPlayer(
            id: try requireID(),
            sid: sid,
            name: name,
            number: number,
            nationality: nationality,
            eligilibity: eligibility,
            image: image ?? "",
            status: status ?? false,
            team: team,
            email: email ?? "",
            balance: balance ?? 0,
            events: events,
            stats: stats,
            nextMatch: nextMatches,
            position: position,
            birthDate: birthday
        )
    }

    func toAppPlayerOverview(
        team: AppModels.AppTeamOverview,
        stats: PlayerStats? = nil,
        nextMatches: [AppModels.NextMatch] = []
    ) throws -> AppModels.AppPlayerOverview {
        AppModels.AppPlayerOverview(
            id: try requireID(),
            sid: sid,
            name: name,
            number: number,
            nationality: nationality,
            eligilibity: eligibility,
            image: image ?? "",
            status: status ?? false,
            team: team,
            nextMatch: nextMatches
        )
    }
    
    func toAppPlayerOverviewMatchEvent(
        team: AppModels.AppTeamOverview,
        stats: PlayerStats? = nil,
        nextMatches: [AppModels.NextMatch] = []
    ) throws -> AppModels.AppPlayerMatchEventWrapper {
        AppModels.AppPlayerMatchEventWrapper(
            id: try requireID(),
            sid: sid,
            name: name,
            number: number,
            nationality: nationality,
            eligilibity: eligibility,
            image: image ?? ""
        )
    }
}

