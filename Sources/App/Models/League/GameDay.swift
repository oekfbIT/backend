//
//  File.swift
//  
//
//  Created by Alon Yakoby on 26.04.24.
//

import Foundation
import Vapor
import Fluent

final class GameDay: Model, Content, Codable {
    static let schema = "gameDay"

    @ID(custom: "id") var id: UUID?
    @Field(key: FieldKeys.details) var details: Int
    @Field(key: FieldKeys.date) var date: Date

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var details: FieldKey { "details" }
        static var date: FieldKey { "date" }
    }

    init() {}

    init(id: UUID? = nil, details: Int, date: Date) {
        self.id = id
        self.details = details
        self.date = date
    }
}

extension GameDay: Mergeable {
    func merge(from other: GameDay) -> GameDay {
        var merged = self
        merged.id = other.id
        merged.details = other.details
        merged.date = other.date
        return merged
    }
}


// Migration for GameDay
extension GameDay: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(GameDay.schema)
            .field(FieldKeys.id, .uuid, .identifier(auto: true))
            .field(FieldKeys.details, .int, .required)
            .field(FieldKeys.date, .datetime, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(GameDay.schema).delete()
    }
}
