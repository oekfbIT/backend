//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

final class Stadium: Model, Content, Codable {
    static let schema = "stadiums"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.code) var code: String
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.address) var address: String
    @Field(key: FieldKeys.type) var type: Belag
    @Field(key: FieldKeys.schuhwerk) var schuhwerk: Schuhwerk
    @Field(key: FieldKeys.flutlicht) var flutlicht: Bool
    @Field(key: FieldKeys.parking) var parking: Bool
    @Field(key: FieldKeys.homeTeam) var homeTeam: String
    @Field(key: FieldKeys.partnerSince) var partnerSince: String

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static let code: FieldKey = "code"
        static let name: FieldKey = "name"
        static let address: FieldKey = "address"
        static let type: FieldKey = "type"
        static let schuhwerk: FieldKey = "schuhwerk"
        static let flutlicht: FieldKey = "flutlicht"
        static let parking: FieldKey = "parking"
        static let homeTeam: FieldKey = "homeTeam"
        static let partnerSince: FieldKey = "partnerSince"
    }

    init() {}

    init(id: UUID? = nil, code: String, name: String, address: String, type: Belag, schuhwerk: Schuhwerk, flutlicht: Bool, parking: Bool, homeTeam: String, partnerSince: String) {
        self.id = id
        self.code = code
        self.name = name
        self.address = address
        self.type = type
        self.schuhwerk = schuhwerk
        self.flutlicht = flutlicht
        self.parking = parking
        self.homeTeam = homeTeam
        self.partnerSince = partnerSince
    }
}

// Stadium Migration
extension StadiumMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Stadium.schema)
            .field(Stadium.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Stadium.FieldKeys.code, .string, .required)
            .field(Stadium.FieldKeys.name, .string, .required)
            .field(Stadium.FieldKeys.address, .string, .required)
            .field(Stadium.FieldKeys.type, .string, .required)
            .field(Stadium.FieldKeys.schuhwerk, .string, .required)
            .field(Stadium.FieldKeys.flutlicht, .bool, .required)
            .field(Stadium.FieldKeys.parking, .bool, .required)
            .field(Stadium.FieldKeys.homeTeam, .string, .required)
            .field(Stadium.FieldKeys.partnerSince, .string, .required)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Stadium.schema).delete()
    }
}

enum Belag: String, Codable {
    case kunstrasen
    
    var value: String {
        switch self {
            case .kunstrasen: return "Kunstrasen"
        }
    }
}

enum Schuhwerk: String, Codable {
    case kunstrasen
    
    var value: String {
        switch self {
            case .kunstrasen: return "Kunstrasen"
        }
    }
}
