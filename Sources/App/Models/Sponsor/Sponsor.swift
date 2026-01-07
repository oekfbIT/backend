//
//  File.swift
//
//  Created by Alon Yakoby on 23.04.24.
//

import Foundation
import Fluent
import Vapor


enum SponsorType: String, Codable {
    case sponsor
    case partner
}


final class Sponsor: Model, Content, Codable {
    static let schema = "sponsor"

    @ID(custom: FieldKeys.id)
    var id: UUID?

    @OptionalField(key: FieldKeys.name)
    var name: String?

    @OptionalField(key: FieldKeys.link)
    var link: String?

    @OptionalField(key: FieldKeys.logo)
    var logo: String?

    @OptionalField(key: FieldKeys.description)
    var description: String?

    @OptionalEnum(key: FieldKeys.type)
    var type: SponsorType?

    @Timestamp(key: FieldKeys.created, on: .create)
    var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var name: FieldKey { "name" }
        static var link: FieldKey { "link" }
        static var logo: FieldKey { "logo" }
        static var description: FieldKey { "description" }
        static var type: FieldKey { "type" }
        static var created: FieldKey { "created" }
    }

    init() {}

    init(
        id: UUID? = nil,
        name: String?,
        link: String?,
        logo: String?,
        description: String? = nil,
        type: SponsorType? = nil,
        created: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.link = link
        self.logo = logo
        self.description = description
        self.type = type
        self.created = created
    }
}


extension Sponsor: Mergeable {
    func merge(from other: Sponsor) -> Sponsor {
        var merged = self
        merged.name = other.name ?? self.name
        merged.link = other.link ?? self.link
        merged.logo = other.logo ?? self.logo
        merged.description = other.description ?? self.description
        merged.type = other.type ?? self.type
        merged.created = other.created ?? self.created
        return merged
    }
}


extension SponsorMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Sponsor.schema)
            .id()
            .field(Sponsor.FieldKeys.name, .string)
            .field(Sponsor.FieldKeys.logo, .string)
            .field(Sponsor.FieldKeys.link, .string)
            .field(Sponsor.FieldKeys.description, .string)
            .field(Sponsor.FieldKeys.type, .string)
            .field(Sponsor.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Sponsor.schema).delete()
    }
}
