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
    @OptionalParent(key: FieldKeys.userId) var user: User?
    @OptionalField(key: FieldKeys.balance) var balance: Double?
    @OptionalField(key: FieldKeys.name) var name: String?
    @Children(for: \.$referee) var assignments: [Match]
    @OptionalField(key: FieldKeys.identification) var identification: String?
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalField(key: FieldKeys.nationality) var nationality: String?
    enum FieldKeys {
        static var id: FieldKey { "id" }
        static var userId: FieldKey { "userId" }
        static var name: FieldKey { "name" }
        static var image: FieldKey { "image" }
        static var assignments: FieldKey { "assignments" }
        static var balance: FieldKey { "balance" }
        static var identification: FieldKey { "identification" }
        static var nationality: FieldKey { "nationality" }
    }

    init() {}

    init(id: UUID? = nil, userId: UUID? = nil, balance: Double? = 0, name: String?, identification: String?, image: String?, nationality: String?) {
        self.id = id
        self.$user.id = userId
        self.balance = balance
        self.name = name ?? ""
        self.identification = identification
        self.image = image
        self.nationality = nationality
    }
}

extension Referee: Mergeable {
    func merge(from other: Referee) -> Referee {
        var merged = self
        merged.id = other.id
        merged.$user.id = other.$user.id
        merged.balance = other.balance
        merged.name = other.name
        merged.identification = other.identification
        merged.image = other.image
        merged.nationality = other.nationality
        return merged
    }
}

// Referee Migration
extension Referee: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Referee.schema)
            .field(Referee.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Referee.FieldKeys.userId, .uuid, .required, .references(User.schema, User.FieldKeys.id))
            .field(Referee.FieldKeys.balance, .double)
            .field(Referee.FieldKeys.name, .string)
            .field(Referee.FieldKeys.identification, .string)
            .field(Referee.FieldKeys.image, .string)
            .field(Referee.FieldKeys.nationality, .string)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Referee.schema).delete()
    }
}

