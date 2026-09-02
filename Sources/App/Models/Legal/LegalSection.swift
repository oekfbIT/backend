import Foundation
import Fluent
import Vapor

enum LegalDocumentType: String, Codable, CaseIterable {
    case regeln
    case ligaordnung
    case bund

    var usesParagraphNumbers: Bool {
        self != .bund
    }
}

final class LegalSection: Model, Content {
    static let schema = "legal_sections"

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var documentType: FieldKey { "document_type" }
        static var heading: FieldKey { "heading" }
        static var content: FieldKey { "content" }
        static var position: FieldKey { "position" }
        static var createdAt: FieldKey { "created_at" }
        static var updatedAt: FieldKey { "updated_at" }
    }

    @ID(custom: FieldKeys.id)
    var id: UUID?

    @Enum(key: FieldKeys.documentType)
    var documentType: LegalDocumentType

    @Field(key: FieldKeys.heading)
    var heading: String

    @Field(key: FieldKeys.content)
    var content: String

    @Field(key: FieldKeys.position)
    var position: Int

    @Timestamp(key: FieldKeys.createdAt, on: .create)
    var createdAt: Date?

    @Timestamp(key: FieldKeys.updatedAt, on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        documentType: LegalDocumentType,
        heading: String,
        content: String,
        position: Int
    ) {
        self.id = id
        self.documentType = documentType
        self.heading = heading
        self.content = content
        self.position = position
    }
}

struct LegalSectionMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(LegalSection.schema)
            .field(LegalSection.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(LegalSection.FieldKeys.documentType, .string, .required)
            .field(LegalSection.FieldKeys.heading, .string, .required)
            .field(LegalSection.FieldKeys.content, .string, .required)
            .field(LegalSection.FieldKeys.position, .int, .required)
            .field(LegalSection.FieldKeys.createdAt, .datetime)
            .field(LegalSection.FieldKeys.updatedAt, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(LegalSection.schema).delete()
    }
}
