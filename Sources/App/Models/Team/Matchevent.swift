//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

enum MatchAssignment : String, Codable {
    case home, away
}

final class MatchEvent: Model, Content, Codable {
    static let schema = "match_events"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.type) var type: MatchEventType
    @Parent(key: FieldKeys.playerId) var player: Player
    @Field(key: FieldKeys.minute) var minute: Int
    @Parent(key: FieldKeys.match) var match: Match
    
    @OptionalField(key: FieldKeys.name) var name: String?
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalField(key: FieldKeys.number) var number: String?
    @OptionalField(key: FieldKeys.assign) var assign: MatchAssignment?
    @OptionalField(key: FieldKeys.ownGoal) var ownGoal: Bool?

    enum FieldKeys {
        static let id: FieldKey = "id"
        static let type: FieldKey = "type"
        static let match: FieldKey = "match"
        static let playerId: FieldKey = "playerId"
        static let minute: FieldKey = "minute"
        
        static let name: FieldKey = "name"
        static let image: FieldKey = "image"
        static let number: FieldKey = "number"
        static let assign: FieldKey = "assign"
        static let ownGoal: FieldKey = "ownGoal"
    }

    init() {}

    init(id: UUID? = nil, match: Match.IDValue, type: MatchEventType, playerId: UUID, minute: Int, name: String?, image: String?, number: String?, assign: MatchAssignment? = nil, ownGoal: Bool? = nil) {
        self.id = id
        self.$match.id = match
        self.type = type
        self.minute = minute
        self.$player.id = playerId
        self.name = name
        self.image = image
        self.number = number
        self.assign = assign
        self.ownGoal = ownGoal
    }
}

// MatchEvent Migration
extension MatchEventMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchEvent.schema)
            .field(MatchEvent.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(MatchEvent.FieldKeys.type, .string, .required)
            .field(MatchEvent.FieldKeys.playerId, .uuid, .required, .references(Player.schema, Player.FieldKeys.id))
            .field(MatchEvent.FieldKeys.minute, .int, .required)
            .field(MatchEvent.FieldKeys.name, .string)
            .field(MatchEvent.FieldKeys.image, .string)
            .field(MatchEvent.FieldKeys.number, .string)
            .field(MatchEvent.FieldKeys.assign, .string)
            .field(MatchEvent.FieldKeys.ownGoal, .bool)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchEvent.schema).delete()
    }
}
