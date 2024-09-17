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
    @Field(key: FieldKeys.bundesland) var bundesland: Bundesland
    @Field(key: FieldKeys.code) var code: String
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.address) var address: String
    @OptionalField(key: FieldKeys.image) var image: String?
    @Field(key: FieldKeys.type) var type: String
    @Field(key: FieldKeys.schuhwerk) var schuhwerk: String
    @Field(key: FieldKeys.flutlicht) var flutlicht: Bool
    @Field(key: FieldKeys.parking) var parking: Bool
    @Field(key: FieldKeys.homeTeam) var homeTeam: String?
    @Field(key: FieldKeys.partnerSince) var partnerSince: String?

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static let code: FieldKey = "code"
        static let name: FieldKey = "name"
        static let bundesland: FieldKey = "bundesland"
        static let address: FieldKey = "address"
        static let type: FieldKey = "type"
        static let image: FieldKey = "image"
        static let schuhwerk: FieldKey = "schuhwerk"
        static let flutlicht: FieldKey = "flutlicht"
        static let parking: FieldKey = "parking"
        static let homeTeam: FieldKey = "homeTeam"
        static let partnerSince: FieldKey = "partnerSince"
    }

    init() {}

    init(id: UUID? = nil, bundesland: Bundesland, code: String, name: String, address: String, image: String? = nil, type: String, schuhwerk: String, flutlicht: Bool, parking: Bool, homeTeam: String?, partnerSince: String?) {
        self.id = id
        self.bundesland = bundesland
        self.code = code
        self.name = name
        self.address = address
        self.image = image
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
            .field(Stadium.FieldKeys.bundesland, .string, .required)
            .field(Stadium.FieldKeys.code, .string, .required)
            .field(Stadium.FieldKeys.name, .string, .required)
            .field(Stadium.FieldKeys.address, .string, .required)
            .field(Stadium.FieldKeys.image, .string)
            .field(Stadium.FieldKeys.type, .string)
            .field(Stadium.FieldKeys.schuhwerk, .string)
            .field(Stadium.FieldKeys.flutlicht, .bool)
            .field(Stadium.FieldKeys.parking, .bool)
            .field(Stadium.FieldKeys.homeTeam, .string)
            .field(Stadium.FieldKeys.partnerSince, .string)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Stadium.schema).delete()
    }
}
