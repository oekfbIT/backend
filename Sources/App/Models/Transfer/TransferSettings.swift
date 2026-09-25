import Foundation
import Fluent
import Vapor

final class TransferSettings: Model, Content, Codable {
    static let schema = "transfersSettings"

    @ID(custom: .id) var id: UUID?
    @Field(key: FieldKeys.isTransferOpen) var isTransferOpen: Bool
    @Field(key: FieldKeys.isDressChangeOpen) var isDressChangeOpen: Bool
    @Field(key: FieldKeys.isCancelPossible) var isCancelPossible: Bool
    @OptionalField(key: FieldKeys.isPostponePossible) var isPostponePossible: Bool?
    @Field(key: FieldKeys.showSponsors) var showSponsors: Bool
    @OptionalField(key: FieldKeys.paymentsEnabled) var paymentsEnabled: Bool?
    @Field(key: FieldKeys.fromDate) var fromDate: String
    @OptionalField(key: FieldKeys.minAppVersion) var minAppVersion: String?
    @Field(key: FieldKeys.to) var to: String
    @OptionalField(key: FieldKeys.name) var name: String?
    @Timestamp(key: FieldKeys.created, on: .update) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var isTransferOpen: FieldKey { "isTransferOpen"}
        static var isDressChangeOpen: FieldKey { "isDressChangeOpen"}
        static var isCancelPossible: FieldKey { "isCancelPossible"}
        static var isPostponePossible: FieldKey { "isPostponePossible"}
        static var fromDate: FieldKey { "player"}
        static var to: FieldKey { "status"}
        static var name: FieldKey { "name"}
        static var created: FieldKey { "created"}
        static var showSponsors: FieldKey { "showSponsors"}
        static var paymentsEnabled: FieldKey { "paymentsEnabled"}
        static var minAppVersion: FieldKey { "minAppVersion"}
    }

    init() {}

    init(
        id: UUID? = nil,
        isTransferOpen: Bool,
        isDressChangeOpen: Bool? = false,
        isCancelPossible: Bool? = false,
        isPostponePossible: Bool? = nil,
        showSponsors: Bool? = false,
        paymentsEnabled: Bool? = true,
        fromDate: String,
        to: String,
        name: String?,
        created: Date?,
        minAppVersion: String
    ) {
        self.id = id
        self.isTransferOpen = isTransferOpen
        self.isDressChangeOpen = isDressChangeOpen ?? false
        self.showSponsors = showSponsors ?? false
        self.paymentsEnabled = paymentsEnabled ?? true
        self.isCancelPossible = isCancelPossible ?? false
        self.isPostponePossible = isPostponePossible ?? isCancelPossible ?? false
        self.fromDate = fromDate
        self.to = to
        self.name = name
        self.created = created
        self.minAppVersion = minAppVersion
    }
}

extension TransferSettings: Mergeable {
    func merge(from other: TransferSettings) -> TransferSettings {
        var merged = self
        merged.id = other.id
        merged.isTransferOpen = other.isTransferOpen
        merged.isDressChangeOpen = other.isDressChangeOpen
        merged.isCancelPossible = other.isCancelPossible
        merged.isPostponePossible = other.isPostponePossible
        merged.showSponsors = other.showSponsors
        merged.paymentsEnabled = other.paymentsEnabled
        merged.fromDate = other.fromDate
        merged.to = other.to
        merged.created = other.created
        merged.name = other.name
        merged.minAppVersion = other.minAppVersion
        return merged
    }
}

// Migration
extension TransferSettingsMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TransferSettings.schema)
            .id()
            .field(TransferSettings.FieldKeys.isTransferOpen, .bool, .required)
            .field(TransferSettings.FieldKeys.isDressChangeOpen, .bool, .required)
            .field(TransferSettings.FieldKeys.isCancelPossible, .bool)
            .field(TransferSettings.FieldKeys.showSponsors, .bool)
            .field(TransferSettings.FieldKeys.paymentsEnabled, .bool)
            .field(TransferSettings.FieldKeys.fromDate, .string, .required)
            .field(TransferSettings.FieldKeys.to, .string, .required)
            .field(TransferSettings.FieldKeys.name, .string)
            .field(TransferSettings.FieldKeys.minAppVersion, .string)
            .field(TransferSettings.FieldKeys.created, .string, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TransferSettings.schema).delete()
    }
}

struct TransferSettingsPostponeMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TransferSettings.schema)
            .field(TransferSettings.FieldKeys.isPostponePossible, .bool)
            .update()
            .flatMap {
                TransferSettings.query(on: database)
                    .all()
                    .flatMap { settings in
                        settings.map { setting in
                            guard setting.isPostponePossible == nil else {
                                return database.eventLoop.makeSucceededFuture(())
                            }
                            setting.isPostponePossible = setting.isCancelPossible
                            return setting.update(on: database)
                        }.flatten(on: database.eventLoop)
                    }
            }
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TransferSettings.schema)
            .deleteField(TransferSettings.FieldKeys.isPostponePossible)
            .update()
    }
}
