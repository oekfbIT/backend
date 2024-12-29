import Foundation
import Fluent
import Vapor

enum TransferStatus: String, Codable {
    case angenommen, abgelent, warten, abgelaufen
}

final class Transfer: Model, Content, Codable {
    static let schema = "transfers"

    @ID(custom: .id) var id: UUID?
    @Field(key: FieldKeys.team) var team: UUID
    @Field(key: FieldKeys.player) var player: UUID
    @OptionalField(key: FieldKeys.status) var status: TransferStatus?
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    @OptionalField(key: FieldKeys.origin) var origin: UUID?
    
    @Field(key: FieldKeys.playerName) var playerName: String
    @Field(key: FieldKeys.playerImage) var playerImage: String
    @Field(key: FieldKeys.teamName) var teamName: String
    @Field(key: FieldKeys.teamImage) var teamImage: String
    @OptionalField(key: FieldKeys.originName) var originName: String?
    @OptionalField(key: FieldKeys.originImage) var originImage: String?
    
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var team: FieldKey { "team"}
        static var player: FieldKey { "player"}
        static var origin: FieldKey { "origin"}
        static var status: FieldKey { "status"}
        static var created: FieldKey { "created"}

        static var playerName: FieldKey { "playerName"}
        static var teamName: FieldKey { "teamName"}
        static var playerImage: FieldKey { "playerImage"}
        static var teamImage: FieldKey { "teamImage"}
        static var originName: FieldKey { "originName"}
        static var originImage: FieldKey { "originImage"}
    }

    init() {}

    init(
        id: UUID? = nil,
        team: UUID,
        player: UUID,
        status: TransferStatus? = .warten,
        created: Date?,
        playerName: String,
        playerImage: String,
        teamName: String,
        teamImage: String,
        origin: UUID?,
        originName: String? = nil,
        originImage: String? = nil
    ) {
        self.id = id
        self.team = team
        self.player = player
        self.status = status
        self.created = created
        
        self.playerName = playerName
        self.playerImage = playerImage
        
        self.teamName = teamName
        self.teamImage = teamImage
        
        self.origin = origin
        self.originName = originName
        self.originImage = originImage
    }
}

extension Transfer {
    struct Public: Codable, Content {
        var id: UUID?
        var team: Team.Public
        var player: Player.Public
        var status: TransferStatus?
        var created: Date?
        var playerName: String
        var teamName: String
        var playerImage: String
        var teamImage: String
        var originName: String
        var originImage: String
    }
}


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

// Migration
extension TransferMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Transfer.schema)
            .id()
            .field(Transfer.FieldKeys.team, .uuid, .required)
            .field(Transfer.FieldKeys.player, .uuid, .required)
            .field(Transfer.FieldKeys.status, .string, .required)
            .field(Transfer.FieldKeys.created, .string, .required)
            .field(Transfer.FieldKeys.playerName, .string, .required)
            .field(Transfer.FieldKeys.teamName, .string, .required)
            .field(Transfer.FieldKeys.playerImage, .string, .required)
            .field(Transfer.FieldKeys.teamImage, .string, .required)
            .field(Transfer.FieldKeys.origin, .string)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Transfer.schema).delete()
    }
}


struct PublicTransfer: Codable, Content {
    let id: UUID?
    let created: Date?
    let playerName: String
    let OldteamName: String
    let NewteamName: String
    let playerImage: String
    let teamImage: String
}
