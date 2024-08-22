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

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var team: FieldKey { "team"}
        static var player: FieldKey { "player"}
        static var status: FieldKey { "status"}
        static var created: FieldKey { "created"}
    }

    init() {}

    init(
        id: UUID? = nil,
        team: UUID,
        player: UUID,
        status: TransferStatus? = .warten,
        created: Date?
    ) {
        self.id = id
        self.team = team
        self.player = player
        self.status = status
        self.created = created
        
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
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Transfer.schema).delete()
    }
}
