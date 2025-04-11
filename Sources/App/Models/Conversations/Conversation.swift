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
    @Field(key: FieldKeys.icon) var icon: String?
    @Field(key: FieldKeys.open) var open: Bool?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var team: FieldKey { "team" }
        static var messages: FieldKey { "messages" }
        static var subject: FieldKey { "subject" }
        static var icon: FieldKey { "icon" }
        static var open: FieldKey { "open" }

    }

    init() {}

    init(id: UUID? = nil, teamId: UUID?, subject: String, messages: [Message], open: Bool?) {
        self.id = id
        self.$team.id = teamId
        self.subject = subject
        self.messages = messages
        self.icon = self.$team.wrappedValue?.logo
        self.open = open
    }
}

extension ConversationMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Conversation.schema)
            .field(Conversation.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Conversation.FieldKeys.team, .uuid, .references(Team.schema, Team.FieldKeys.id))
            .field(Conversation.FieldKeys.subject, .string, .required)
            .field(Conversation.FieldKeys.icon, .string)
            .field(Conversation.FieldKeys.open, .bool, .required)
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
        merged.open = other.open
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
    var attachments: [Attachment]?
    var created: Date?
}

struct Attachment: Codable {
    var name: String?
    var url: String?
    var type: String?
}
