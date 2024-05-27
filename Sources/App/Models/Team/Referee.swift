//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

final class Referee: Model, Content, Codable {
    static let schema = "referees"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Parent(key: FieldKeys.userId) var user: User // Ask only for the USERID
    @Children(for: \.$referee) var assignments: [Match]

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static var userId: FieldKey { "userId" }
    }

    init() {}

    init(id: UUID? = nil, userId: UUID) {
        self.id = id
        self.$user.id = userId
    }
}

// Referee Migration
extension Referee: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Referee.schema)
            .field(FieldKeys.id, .uuid, .identifier(auto: true))
            .field(FieldKeys.userId, .uuid, .required, .references(User.schema, User.FieldKeys.id))
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Referee.schema).delete()
    }
}
