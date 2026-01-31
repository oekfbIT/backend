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

final class Season: Model, Content {
    static let schema = "seasons"

    @ID(custom: "id") var id: UUID?
    @OptionalParent(key: FieldKeys.league) var league: League?
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.details) var details: Int
    @OptionalField(key: FieldKeys.primary) var primary: Bool?
    @OptionalField(key: FieldKeys.table) var table: SeasonTable?
    @OptionalField(key: FieldKeys.winner) var winner: UUID?
    @OptionalField(key: FieldKeys.runnerup) var runnerup: UUID?
    @Children(for: \.$season) var matches: [Match]
    @OptionalField(key: FieldKeys.gameday) var gameday: Int?

    // IMPORTANT:
    // Exclude `matches` from Codable/Content encoding to prevent:
    // "Children relation not eager loaded" crashes during response encoding.
    enum CodingKeys: String, CodingKey {
        case id
        case league
        case name
        case details
        case primary
        case table
        case winner
        case runnerup
        case gameday
    }

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var name: FieldKey { "name" }
        static var match: FieldKey { "match" }
        static var league: FieldKey { "league" }
        static var state: FieldKey { "state" }
        static var details: FieldKey { "details" }
        static var primary: FieldKey { "primary" }
        static var table: FieldKey { "table" }
        static var winner: FieldKey { "winner" }
        static var runnerup: FieldKey { "runnerup" }
        static var gameday: FieldKey { "gameday" }
    }

    init() {}

    init(
        id: UUID? = nil,
        leagueId: UUID? = nil,
        name: String,
        details: Int,
        primary: Bool?,
        table: SeasonTable? = nil,
        winner: UUID? = nil,
        runnerup: UUID? = nil,
        gameday: Int? = 0
    ) {
        self.id = id
        self.$league.id = leagueId
        self.name = name
        self.details = details
        self.primary = primary
        self.table = table
        self.winner = winner
        self.runnerup = runnerup
        self.gameday = gameday
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
            .field(FieldKeys.winner, .uuid)
            .field(FieldKeys.runnerup, .uuid)
            .field(FieldKeys.gameday, .int)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema).delete()
    }
}

extension Season {
    func toAppSeason() throws -> AppModels.AppSeason {
        AppModels.AppSeason(
            id: try requireID().uuidString,
            league: league?.name ?? "",
            leagueId: try $league.id ?? UUID(),
            name: name
        )
    }
}
