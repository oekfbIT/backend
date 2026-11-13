import Fluent
import Vapor

final class Offer: Model, Content {
    static let schema = "offers"

    @ID(key: .id) var id: UUID?
    @Field(key: "starts_at") var startsAt: Date
    @Field(key: "ends_at") var endsAt: Date
    @Field(key: "company_name") var companyName: String
    @Field(key: "logo") var logo: String
    @Field(key: "affiliate_url") var affiliateUrl: String
    @Field(key: "description") var description: String

    init() {}
}

struct CreateOffers: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Offer.schema).id()
            .field("starts_at", .datetime, .required)
            .field("ends_at", .datetime, .required)
            .field("company_name", .string, .required)
            .field("logo", .string, .required)
            .field("affiliate_url", .string, .required)
            .field("description", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Offer.schema).delete()
    }
}

struct OfferInput: Content {
    let startsAt: Date
    let endsAt: Date
    let companyName: String
    let logo: String
    let affiliateUrl: String
    let description: String

    func apply(to offer: Offer) throws {
        guard startsAt < endsAt else {
            throw Abort(.badRequest, reason: "Offer end must be after its start.")
        }
        let name = try SponsorSupport.normalizedName(companyName)
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Abort(.badRequest, reason: "Description must not be empty.")
        }
        let logoURL = try SponsorSupport.validatedURL(logo, field: "Logo")
        let link = try SponsorSupport.validatedURL(affiliateUrl, field: "Affiliate URL")
        offer.startsAt = startsAt
        offer.endsAt = endsAt
        offer.companyName = name
        offer.logo = logoURL
        offer.affiliateUrl = link
        offer.description = text
    }
}

extension AdminController {
    func setupOfferRoutes(on root: RoutesBuilder) {
        let offers = root.grouped("offers")
        offers.get { req async throws -> [Offer] in
            try await Offer.query(on: req.db).sort(\.$startsAt, .descending).all()
        }
        offers.post { req async throws -> Offer in
            let offer = Offer()
            try req.content.decode(OfferInput.self).apply(to: offer)
            try await offer.create(on: req.db)
            return offer
        }
        offers.put(":id") { req async throws -> Offer in
            let id = try req.parameters.require("id", as: UUID.self)
            guard let offer = try await Offer.find(id, on: req.db) else { throw Abort(.notFound) }
            try req.content.decode(OfferInput.self).apply(to: offer)
            try await offer.update(on: req.db)
            return offer
        }
        offers.delete(":id") { req async throws -> HTTPStatus in
            let id = try req.parameters.require("id", as: UUID.self)
            guard let offer = try await Offer.find(id, on: req.db) else { throw Abort(.notFound) }
            try await offer.delete(on: req.db)
            return .noContent
        }
    }
}

extension AppController {
    func setupOfferRoutes(on root: RoutesBuilder) {
        root.get("offers") { req async throws -> [Offer] in
            let now = Date()
            return try await Offer.query(on: req.db)
                .filter(\.$startsAt <= now)
                .filter(\.$endsAt > now)
                .sort(\.$startsAt, .ascending)
                .sort(\.$id, .ascending)
                .all()
        }
    }
}
