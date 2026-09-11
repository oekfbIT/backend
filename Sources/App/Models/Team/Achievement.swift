import Fluent
import Vapor
import Foundation

/// A manually awarded achievement belonging to one team or player.
final class Achievement: Model, Content {
    static let schema = "achievements"
    @ID(custom: "id") var id: UUID?
    @Field(key: "label") var label: String
    @OptionalField(key: "image_url") var imageUrl: String?
    @Field(key: "owner_type") var ownerType: String
    @Field(key: "owner_id") var ownerId: UUID
    init() {}
    init(label: String, imageUrl: String?, ownerType: String, ownerId: UUID) {
        self.label = label
        self.imageUrl = imageUrl
        self.ownerType = ownerType
        self.ownerId = ownerId
    }
}

struct AchievementMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Achievement.schema)
            .field("id", .uuid, .identifier(auto: true))
            .field("label", .string, .required)
            .field("image_url", .string)
            .field("owner_type", .string, .required)
            .field("owner_id", .uuid, .required)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema(Achievement.schema).delete()
    }
}

struct AchievementInput: Content {
    let label: String
    let imageUrl: String?

    func normalized() throws -> (String, String?) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 200 else {
            throw Abort(.badRequest, reason: "Label must contain 1–200 characters.")
        }
        let image = imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let image = image, !image.isEmpty else { return (label, nil) }
        guard image.count <= 2048, let url = URL(string: image),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            throw Abort(.badRequest, reason: "Image must be an HTTP or HTTPS URL.")
        }
        return (label, image)
    }
}

struct AchievementSupport {
    static func owner(_ req: Request) async throws -> (String, UUID) {
        let type = try req.parameters.require("ownerType", as: String.self)
        let id = try req.parameters.require("ownerId", as: UUID.self)
        switch type {
        case "team":
            guard try await Team.find(id, on: req.db) != nil else { throw Abort(.notFound) }
        case "player":
            guard try await Player.find(id, on: req.db) != nil else { throw Abort(.notFound) }
        default: throw Abort(.badRequest, reason: "Owner must be team or player.")
        }
        return (type, id)
    }
    static func list(req: Request) async throws -> [Achievement] {
        let (type, id) = try await owner(req)
        return try await Achievement.query(on: req.db)
            .filter(\.$ownerType == type).filter(\.$ownerId == id)
            .sort(\.$label).sort(\.$id).all()
    }
    static func item(_ req: Request) async throws -> Achievement {
        let (type, ownerId) = try await owner(req)
        let id = try req.parameters.require("achievementId", as: UUID.self)
        guard let item = try await Achievement.find(id, on: req.db),
              item.ownerType == type, item.ownerId == ownerId else { throw Abort(.notFound) }
        return item
    }
}
