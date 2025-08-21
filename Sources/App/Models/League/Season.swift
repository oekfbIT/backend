//
//  File.swift
//  
//
//  Created by Alon Yakoby on 26.04.24.
//

import Foundation
import Fluent
import Vapor

struct SeasonTable: Codable, Content {
    var name: String
    var table: [TableItem]
}

final class Season: Model, Content, Codable {
    static let schema = "seasons"

    @ID(custom: "id") var id: UUID?
    @OptionalParent(key: FieldKeys.league) var league: League?
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.details) var details: Int
    @OptionalField(key: FieldKeys.primary) var primary: Bool?
    @OptionalField(key: FieldKeys.table) var table: SeasonTable?
    @Children(for: \.$season) var matches: [Match]

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var name: FieldKey { "name" }
        static var match: FieldKey { "match" }
        static var league: FieldKey { "league"}
        static var state: FieldKey { "state" }
        static var details: FieldKey { "details" }
        static var primary: FieldKey { "primary" }
        static var table: FieldKey { "table" }
    }

    init() {}

    init(id: UUID? = nil, leagueId: UUID? = nil, name: String, details: Int, primary: Bool?, table: SeasonTable? = nil) {
        self.id = id
        self.$league.id = leagueId
        self.name = name
        self.details = details
        self.primary = primary
        self.table = table
    }
}

// Season Migration
extension Season: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema)
            .field(FieldKeys.id, .uuid, .identifier(auto: true))
            .field(FieldKeys.name, .string)
            .field(FieldKeys.state, .string)
            .field(FieldKeys.table, .json)
            .field(FieldKeys.primary, .bool)
            .field(FieldKeys.details, .int, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema).delete()
    }
}
