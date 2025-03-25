//
//  File.swift
//
//
//  Created by Alon Yakoby on 23.04.24.
//

import Foundation
import Fluent
import Vapor

final class Strafsenat: Model, Content, Codable {
    static let schema = "strafsenat"

    @ID(custom: FieldKeys.id) var id: UUID?
    @OptionalField(key: FieldKeys.text) var text: String?
    @Parent(key: FieldKeys.matchID) var match: Match
    @Field(key: FieldKeys.refID) var refID: UUID
    @Field(key: FieldKeys.offen) var offen: Bool
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var text: FieldKey { "text" }
        static var matchID: FieldKey { "matchID" }
        static var refID: FieldKey { "refID" }
        static var offen: FieldKey { "offen" }
        static var created: FieldKey { "created" }
    }

    init() {}
    
    init(id: UUID? = nil,
         matchID: UUID,
         refID: UUID,
         text: String? = nil,
         created: Date? = nil,
         offen: Bool? = true) {
        self.id = id
        self.$match.id = matchID
        self.refID = refID
        self.text = text
        self.offen = offen ?? true
        self.created = created
    }
}

extension Strafsenat: Mergeable {
    func merge(from other: Strafsenat) -> Strafsenat {
        var merged = self
        merged.match = other.match
        merged.refID = other.refID
        merged.offen = other.offen
        merged.text = other.text ?? self.text
        merged.created = other.created ?? self.created
        return merged
    }
}

extension StrafsenatMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Strafsenat.schema)
            .id()
            .field(Strafsenat.FieldKeys.matchID, .uuid, .references(Match.schema, .id))
            .field(Strafsenat.FieldKeys.refID, .uuid, .required)
            .field(Strafsenat.FieldKeys.text, .string)
            .field(Strafsenat.FieldKeys.offen, .bool)
            .field(Strafsenat.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Strafsenat.schema).delete()
    }
}
