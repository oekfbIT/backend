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

struct CurrentSeasonResponse: Content {
    let id: UUID?
    let name: String
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
    @OptionalField(key: FieldKeys.startDate) var startDate: Date?
    @OptionalField(key: FieldKeys.endDate) var endDate: Date?
    @Children(for: \.$season) var matches: [Match]
    @OptionalField(key: FieldKeys.gameday) var gameday: Int? // Gameday should never be more then season matches.gameday unique list if theres 20 gamedays this cant be 21

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
        case startDate
        case endDate
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
        static var startDate: FieldKey { "startDate" }
        static var endDate: FieldKey { "endDate" }
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
        startDate: Date? = nil,
        endDate: Date? = nil,
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
        self.startDate = startDate
        self.endDate = endDate
        self.gameday = gameday
    }
}

/// Adds optional season boundaries without requiring values for legacy rows.
struct SeasonDateRangeMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema)
            .field(Season.FieldKeys.startDate, .date)
            .field(Season.FieldKeys.endDate, .date)
            .update()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema)
            .deleteField(Season.FieldKeys.startDate)
            .deleteField(Season.FieldKeys.endDate)
            .update()
    }
}

extension Season {
    /// Derives the boundaries from the earliest and latest dated match.
    /// Seasons without dated matches intentionally keep both values nil.
    func syncDateRange(on database: Database) async throws {
        let seasonID = try requireID()
        let dates = try await Match.query(on: database)
            .filter(\.$season.$id == seasonID)
            .all()
            .compactMap(\.details.date)

        let newStartDate = dates.min()
        let newEndDate = dates.max()
        guard startDate != newStartDate || endDate != newEndDate else { return }

        startDate = newStartDate
        endDate = newEndDate
        try await save(on: database)
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
