import Fluent
import Vapor

extension AdminController {
    func setupSponsorRoutes(on root: RoutesBuilder) {
        let sponsors = root.grouped("sponsors")
        sponsors.get(use: getAdminSponsors)
        sponsors.post(use: createSponsor)
        sponsors.patch(":id", use: updateSponsor)
        sponsors.delete(":id", use: deleteSponsor)
        sponsors.put("order", use: reorderSponsors)
    }
}

extension AdminController {
    struct CreateSponsorRequest: Content {
        let name: String
        let link: String
        let logo: String
        let type: SponsorType
        let position: Int?
    }

    struct UpdateSponsorRequest: Content {
        let name: String?
        let link: String?
        let logo: String?
        let type: SponsorType?
        let position: Int?
    }

    struct ReorderSponsorsRequest: Content {
        let sponsorIds: [UUID]
    }

    func getAdminSponsors(req: Request) async throws -> [Sponsor] {
        try await SponsorSupport.all(on: req.db)
    }

    func createSponsor(req: Request) async throws -> [Sponsor] {
        let body = try req.content.decode(CreateSponsorRequest.self)
        var items = try await SponsorSupport.all(on: req.db)
        let item = Sponsor(
            name: try SponsorSupport.normalizedName(body.name),
            link: try SponsorSupport.validatedURL(body.link, field: "Link"),
            logo: try SponsorSupport.validatedURL(body.logo, field: "Logo"),
            type: body.type,
            position: items.count + 1
        )
        try await item.create(on: req.db)

        let target = min(max((body.position ?? items.count + 1) - 1, 0), items.count)
        items.insert(item, at: target)
        try await SponsorSupport.persistCanonicalOrder(items, on: req.db)
        return try await SponsorSupport.all(on: req.db)
    }

    func updateSponsor(req: Request) async throws -> [Sponsor] {
        let id = try req.parameters.require("id", as: UUID.self)
        let body = try req.content.decode(UpdateSponsorRequest.self)
        var items = try await SponsorSupport.all(on: req.db)
        guard let currentIndex = items.firstIndex(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Sponsor or partner not found.")
        }

        let item = items[currentIndex]
        if let name = body.name { item.name = try SponsorSupport.normalizedName(name) }
        if let link = body.link { item.link = try SponsorSupport.validatedURL(link, field: "Link") }
        if let logo = body.logo { item.logo = try SponsorSupport.validatedURL(logo, field: "Logo") }
        if let type = body.type { item.type = type }
        try await item.update(on: req.db)

        if let position = body.position {
            items.remove(at: currentIndex)
            items.insert(item, at: min(max(position - 1, 0), items.count))
        }
        try await SponsorSupport.persistCanonicalOrder(items, on: req.db)
        return try await SponsorSupport.all(on: req.db)
    }

    func deleteSponsor(req: Request) async throws -> [Sponsor] {
        let id = try req.parameters.require("id", as: UUID.self)
        var items = try await SponsorSupport.all(on: req.db)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Sponsor or partner not found.")
        }
        let item = items.remove(at: index)
        try await item.delete(on: req.db)
        try await SponsorSupport.persistCanonicalOrder(items, on: req.db)
        return try await SponsorSupport.all(on: req.db)
    }

    func reorderSponsors(req: Request) async throws -> [Sponsor] {
        let body = try req.content.decode(ReorderSponsorsRequest.self)
        let items = try await SponsorSupport.all(on: req.db)
        let byID = Dictionary(uniqueKeysWithValues: try items.map { (try $0.requireID(), $0) })

        guard body.sponsorIds.count == items.count,
              Set(body.sponsorIds).count == items.count,
              body.sponsorIds.allSatisfy({ byID[$0] != nil }) else {
            throw Abort(.badRequest, reason: "sponsor_ids must contain every item exactly once.")
        }

        try await SponsorSupport.persistCanonicalOrder(body.sponsorIds.compactMap { byID[$0] }, on: req.db)
        return try await SponsorSupport.all(on: req.db)
    }
}
