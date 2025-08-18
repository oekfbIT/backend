import Foundation
import Fluent
import Vapor

// MARK: - DTOs

/// Payload accepted from the client when creating a transfer (snake_case in JSON).
// MARK: - DTOs

/// Accepts either snake_case or camelCase keys.
struct CreateTransferDTO: Content {
    let team: UUID
    let player: UUID
    let playerName: String
    let playerImage: String
    let teamName: String
    let teamImage: String

    private enum K: String, CodingKey {
        case team, player
        // snake_case
        case player_name, player_image, team_name, team_image
        // camelCase
        case playerName, playerImage, teamName, teamImage
    }

    init(team: UUID, player: UUID, playerName: String, playerImage: String, teamName: String, teamImage: String) {
        self.team = team
        self.player = player
        self.playerName = playerName
        self.playerImage = playerImage
        self.teamName = teamName
        self.teamImage = teamImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)

        self.team = try c.decode(UUID.self, forKey: .team)
        self.player = try c.decode(UUID.self, forKey: .player)

        // try snake_case first, then camelCase
        self.playerName  = try c.decodeIfPresent(String.self, forKey: .player_name)
                          ?? c.decode(String.self, forKey: .playerName)
        self.playerImage = try c.decodeIfPresent(String.self, forKey: .player_image)
                          ?? c.decode(String.self, forKey: .playerImage)
        self.teamName    = try c.decodeIfPresent(String.self, forKey: .team_name)
                          ?? c.decode(String.self, forKey: .teamName)
        self.teamImage   = try c.decodeIfPresent(String.self, forKey: .team_image)
                          ?? c.decode(String.self, forKey: .teamImage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(team, forKey: .team)
        try c.encode(player, forKey: .player)
        try c.encode(playerName, forKey: .playerName)
        try c.encode(playerImage, forKey: .playerImage)
        try c.encode(teamName, forKey: .teamName)
        try c.encode(teamImage, forKey: .teamImage)
    }
}

// MARK: - Model

enum TransferStatus: String, Codable {
    case angenommen
    case abgelehnt
    case warten
    case abgelaufen

    // Backward compatibility for legacy typo "abgelent"
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "angenommen": self = .angenommen
        case "abgelehnt", "abgelent": self = .abgelehnt
        case "warten": self = .warten
        case "abgelaufen": self = .abgelaufen
        default:
            // Unknown values fallback (you can throw if you prefer strictness)
            self = .warten
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

final class Transfer: Model, Content {
    static let schema = "transfers"

    @ID(custom: .id) var id: UUID?

    @Field(key: FieldKeys.team) var team: UUID
    @Field(key: FieldKeys.player) var player: UUID

    // Keep this non-optional because DB column is required
    @Field(key: FieldKeys.status) var status: TransferStatus

    // Let Fluent set this on creation
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    // Filled by the server from Player's current team
    @OptionalField(key: FieldKeys.origin) var origin: UUID?

    @Field(key: FieldKeys.playerName) var playerName: String
    @Field(key: FieldKeys.playerImage) var playerImage: String
    @Field(key: FieldKeys.teamName) var teamName: String
    @Field(key: FieldKeys.teamImage) var teamImage: String
    @OptionalField(key: FieldKeys.originName) var originName: String?
    @OptionalField(key: FieldKeys.originImage) var originImage: String?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var team: FieldKey { "team" }
        static var player: FieldKey { "player" }
        static var status: FieldKey { "status" }
        static var created: FieldKey { "created" }
        static var origin: FieldKey { "origin" }
        static var playerName: FieldKey { "playerName" }
        static var playerImage: FieldKey { "playerImage" }
        static var teamName: FieldKey { "teamName" }
        static var teamImage: FieldKey { "teamImage" }
        static var originName: FieldKey { "originName" }
        static var originImage: FieldKey { "originImage" }
    }

    init() {}

    init(
        id: UUID? = nil,
        team: UUID,
        player: UUID,
        status: TransferStatus,
        playerName: String,
        playerImage: String,
        teamName: String,
        teamImage: String,
        origin: UUID? = nil,
        originName: String? = nil,
        originImage: String? = nil
    ) {
        self.id = id
        self.team = team
        self.player = player
        self.status = status
        self.playerName = playerName
        self.playerImage = playerImage
        self.teamName = teamName
        self.teamImage = teamImage
        self.origin = origin
        self.originName = originName
        self.originImage = originImage
    }
}

// Public representation if you need it elsewhere
extension Transfer {
    struct Public: Codable, Content {
        var id: UUID?
        var team: Team.Public
        var player: Player.Public
        var status: TransferStatus
        var created: Date?
        var playerName: String
        var teamName: String
        var playerImage: String
        var teamImage: String
        var originName: String?
        var originImage: String?
    }
}

// If your codebase relies on this
extension Transfer: Mergeable {
    func merge(from other: Transfer) -> Transfer {
        var merged = self
        merged.id = other.id
        merged.team = other.team
        merged.player = other.player
        merged.status = other.status
        merged.created = other.created
        merged.playerName = other.playerName
        merged.teamName = other.teamName
        merged.playerImage = other.playerImage
        merged.teamImage = other.teamImage
        merged.origin = other.origin
        merged.originName = other.originName
        merged.originImage = other.originImage
        return merged
    }
}

// MARK: - Migration

extension TransferMigration: Migration {
    func prepare(on db: Database) -> EventLoopFuture<Void> {
        db.schema(Transfer.schema)
            .id()
            .field(Transfer.FieldKeys.team, .uuid, .required)
            .field(Transfer.FieldKeys.player, .uuid, .required)
            .field(Transfer.FieldKeys.status, .string, .required)
            .field(Transfer.FieldKeys.created, .datetime)         // Timestamp
            .field(Transfer.FieldKeys.playerName, .string, .required)
            .field(Transfer.FieldKeys.playerImage, .string, .required)
            .field(Transfer.FieldKeys.teamName, .string, .required)
            .field(Transfer.FieldKeys.teamImage, .string, .required)
            .field(Transfer.FieldKeys.origin, .uuid)              // UUID, not string
            .field(Transfer.FieldKeys.originName, .string)
            .field(Transfer.FieldKeys.originImage, .string)
            .create()
    }

    func revert(on db: Database) -> EventLoopFuture<Void> {
        db.schema(Transfer.schema).delete()
    }
}
