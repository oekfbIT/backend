//
//  File.swift
//
//
//  Created by Alon Yakoby on 23.04.24.
//

import Foundation
import Fluent
import Vapor

enum VoteResult: String, Codable {
    case home
    case draw
    case away
}

final class VoteItem: Model, Content, Codable {
    static let schema = "vote"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.deviceid) var deviceid: String
    @Field(key: FieldKeys.matchid) var matchid: UUID
    @Field(key: FieldKeys.vote) var vote: VoteResult
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var deviceid: FieldKey { "deviceid" }
        static var matchid: FieldKey { "matchid" }
        static var vote: FieldKey { "vote" }
        static var created: FieldKey { "created" }
    }

    init() {}

    init(id: UUID? = nil, deviceid: String, matchid: UUID, vote: VoteResult) {
        self.id = id
        self.deviceid = deviceid
        self.matchid = matchid
        self.vote = vote
        self.created = Date.viennaNow
    }
}

extension VoteItem: Mergeable {
    func merge(from other: VoteItem) -> VoteItem {
        var merged = self
        merged.deviceid = other.deviceid ?? self.deviceid
        merged.matchid = other.matchid ?? self.matchid
        merged.vote = other.vote ?? self.vote
        merged.created = other.created ?? self.created
        return merged
    }
}

// NewsItem Migration
extension VoteItemMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(VoteItem.schema)
            .field(VoteItem.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(VoteItem.FieldKeys.deviceid, .string)
            .field(VoteItem.FieldKeys.matchid, .uuid)
            .field(VoteItem.FieldKeys.vote, .json)
            .field(VoteItem.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(VoteItem.schema).delete()
    }
}
