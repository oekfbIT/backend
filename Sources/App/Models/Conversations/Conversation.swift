//
//  File.swift
//  
//
//  Created by Alon Yakoby on 22.06.24.
//

import Foundation
import Vapor
import Fluent

final class Conversation: Model, Content {
    static let schema = "conversations"

    @ID(custom: FieldKeys.id) var id: UUID?
    @OptionalParent(key: FieldKeys.team) var team: Team?
    @Field(key: FieldKeys.messages) var messages: [Message]
    @Field(key: FieldKeys.subject) var subject: String

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var team: FieldKey { "team" }
        static var messages: FieldKey { "messages" }
        static var subject: FieldKey { "subject" }
    }

    init() {}

    init(id: UUID? = nil, teamId: UUID?, subject: String, messages: [Message]) {
        self.id = id
        self.$team.id = teamId
        self.subject = subject
        self.messages = messages
    }
}

extension ConversationMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Conversation.schema)
            .field(Conversation.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Conversation.FieldKeys.team, .uuid, .references(Team.schema, Team.FieldKeys.id))
            .field(Conversation.FieldKeys.subject, .string, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Conversation.schema).delete()
    }
}

extension Conversation: Mergeable {
    func merge(from other: Conversation) -> Conversation {
        var merged = self
        merged.subject = other.subject
        merged.$team.id = other.$team.id
        return merged
    }
}

struct Message: Codable {
    var id: UUID?
    var senderTeam: Bool
    var senderName: String?
    var text: String
    var read: Bool?
    var attachments: [String]?
    var created: Date?
}
