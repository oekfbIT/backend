//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

final class MatchEvent: Model, Content, Codable {
    static let schema = "match_events"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.type) var type: MatchEventType
    @Parent(key: FieldKeys.playerId) var player: Player
    @Field(key: FieldKeys.minute) var minute: Int
    @Parent(key: FieldKeys.match) var match: Match

    enum FieldKeys {
        static let id: FieldKey = "id"
        static let type: FieldKey = "type"
        static let match: FieldKey = "match"
        static let playerId: FieldKey = "playerId"
        static let minute: FieldKey = "minute"
    }

    init() {}

    init(id: UUID? = nil, type: MatchEventType, playerId: UUID, minute: Int) {
        self.id = id
        self.type = type
        self.minute = minute
        self.$player.id = playerId
    }
}

// MatchEvent Migration
extension MatchEvent: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchEvent.schema)
            .field(MatchEvent.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(MatchEvent.FieldKeys.type, .string, .required)
            .field(MatchEvent.FieldKeys.playerId, .uuid, .required, .references(Player.schema, Player.FieldKeys.id))
            .field(MatchEvent.FieldKeys.minute, .int, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchEvent.schema).delete()
    }
}
