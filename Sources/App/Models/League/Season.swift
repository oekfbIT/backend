//
//  File.swift
//  
//
//  Created by Alon Yakoby on 26.04.24.
//

import Foundation
import Fluent
import Vapor

enum MatchState: String, Codable {
    case pending, firstHalf, halftime, secondhalf, completed
}

final class Season: Model, Content, Codable {
    static let schema = "seasons"

    @ID(custom: "id") var id: UUID?
    @OptionalParent(key: FieldKeys.league) var league: League?
    @Field(key: FieldKeys.events) var events: String
    @Field(key: FieldKeys.details) var details: Int

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var events: FieldKey { "events" }
        static var match: FieldKey { "match" }
        static var league: FieldKey { "league"}
        static var state: FieldKey { "state" }
        static var details: FieldKey { "details" }
    }

    init() {}

    init(id: UUID? = nil, leagueId: UUID? = nil,  events: String, details: Int) {
        self.id = id
        self.$league.id = leagueId
        self.events = events
        self.details = details
    }
}

// Season Migration
extension Season: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema)
            .field(FieldKeys.id, .uuid, .identifier(auto: true))
            .field(FieldKeys.events, .string, .required)
            .field(FieldKeys.state, .string)
            .field(FieldKeys.details, .int, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Season.schema).delete()
    }
}
