//
//  File.swift
//
//
//  Created by Alon Yakoby on 23.04.24.
//

import Foundation
import Fluent
import Vapor

final class NewsItem: Model, Content, Codable {
    static let schema = "news"

    @ID(custom: FieldKeys.id) var id: UUID?
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalField(key: FieldKeys.text) var text: String?
    @OptionalField(key: FieldKeys.title) var title: String?
    @OptionalField(key: FieldKeys.tag) var tag: String?
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var image: FieldKey { "image" }
        static var text: FieldKey { "text" }
        static var title: FieldKey { "title" }
        static var tag: FieldKey { "tag" }
        static var created: FieldKey { "created" }
    }

    init() {}

    init(id: UUID? = nil, image: String? = nil, text: String? = nil, title: String? = nil, tag: String? = nil) {
        self.id = id
        self.image = image
        self.text = text
        self.title = title
        self.tag = tag
        self.created = Date.viennaNow
    }
}

extension NewsItem: Mergeable {
    func merge(from other: NewsItem) -> NewsItem {
        var merged = self
        merged.image = other.image ?? self.image
        merged.tag = other.tag ?? self.tag
        merged.text = other.text ?? self.text
        merged.title = other.title ?? self.title
        merged.created = other.created ?? self.created
        return merged
    }
}

// NewsItem Migration
extension NewsItemMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(NewsItem.schema)
            .field(NewsItem.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(NewsItem.FieldKeys.image, .string)
            .field(NewsItem.FieldKeys.text, .string)
            .field(NewsItem.FieldKeys.title, .string)
            .field(NewsItem.FieldKeys.tag, .string)
            .field(NewsItem.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(NewsItem.schema).delete()
    }
}
