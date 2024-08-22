import Foundation
import Fluent
import Vapor

final class TransferSettings: Model, Content, Codable {
    static let schema = "transfersSettings"

    @ID(custom: .id) var id: UUID?
    @Field(key: FieldKeys.isTransferOpen) var isTransferOpen: Bool
    @Field(key: FieldKeys.fromDate) var fromDate: String
    @Field(key: FieldKeys.to) var to: String
    @OptionalField(key: FieldKeys.name) var name: String?
    @Timestamp(key: FieldKeys.created, on: .update) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var isTransferOpen: FieldKey { "isTransferOpen"}
        static var fromDate: FieldKey { "player"}
        static var to: FieldKey { "status"}
        static var name: FieldKey { "name"}
        static var created: FieldKey { "created"}
    }

    init() {}

    init(
        id: UUID? = nil,
        isTransferOpen: Bool,
        fromDate: String,
        to: String,
        name: String?,
        created: Date?
    ) {
        self.id = id
        self.isTransferOpen = isTransferOpen
        self.fromDate = fromDate
        self.to = to
        self.name = name
        self.created = created
        
    }
}

extension TransferSettings: Mergeable {
    func merge(from other: TransferSettings) -> TransferSettings {
        var merged = self
        merged.id = other.id
        merged.isTransferOpen = other.isTransferOpen
        merged.fromDate = other.fromDate
        merged.to = other.to
        merged.created = other.created
        merged.name = other.name
        return merged
    }
}

// Migration
extension TransferSettingsMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TransferSettings.schema)
            .id()
            .field(TransferSettings.FieldKeys.isTransferOpen, .bool, .required)
            .field(TransferSettings.FieldKeys.fromDate, .string, .required)
            .field(TransferSettings.FieldKeys.to, .string, .required)
            .field(TransferSettings.FieldKeys.name, .string)
            .field(TransferSettings.FieldKeys.created, .string, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TransferSettings.schema).delete()
    }
}
