//
//  File.swift
//  
//
//  Created by Alon Yakoby on 23.04.24.
//

import Foundation
import Fluent
import Vapor

final class League: Model, Content, Codable {
    static let schema = "leagues"

    @ID(custom: FieldKeys.id) var id: UUID?
    @OptionalField(key: FieldKeys.state) var state: Bundesland?
    @OptionalField(key: FieldKeys.code) var code: String?
    @OptionalField(key: FieldKeys.hourly) var hourly: Double?
    @OptionalField(key: FieldKeys.teamcount) var teamcount: Int?
    @Field(key: FieldKeys.name) var name: String
    @Children(for: \.$league) var teams: [Team]
    @Children(for: \.$league) var seasons: [Season]
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var state: FieldKey { "state" }
        static var hourly: FieldKey { "hourly" }
        static var teamcount: FieldKey { "teamcount" }
        static var code: FieldKey { "code" }
        static var name: FieldKey { "name" }
    }

    init() {}

    init(id: UUID? = nil, state: Bundesland?, teamcount: Int?, code: String, name: String) {
        self.id = id
        self.state = state
        self.code = code
        self.name = name
        self.teamcount = teamcount ?? 14
    }
}

extension League: Mergeable {
    func merge(from other: League) -> League {
        var merged = self
        merged.id = other.id
        merged.state = other.state
        merged.hourly = other.hourly
        merged.code = other.code
        merged.name = other.name
        merged.teamcount = other.teamcount
        return merged
    }
}


// League Migration
extension LeagueMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(League.schema)
            .field(League.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(League.FieldKeys.state, .string, .required)
            .field(League.FieldKeys.code, .string)
            .field(League.FieldKeys.hourly, .double)
            .field(League.FieldKeys.teamcount, .int)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(League.schema).delete()
    }
}
