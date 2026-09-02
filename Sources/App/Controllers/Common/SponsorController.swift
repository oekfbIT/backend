//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class SponsorController: RouteCollection {
    let path: String

    init(path: String) {
        self.path = path
    }

    func boot(routes: RoutesBuilder) throws {
        let sponsor = routes.grouped(PathComponent(stringLiteral: path))
        sponsor.get(use: getAll)
        sponsor.get("sponsors", use: getSponsors)
        sponsor.get("partners", use: getPartners)
    }

    func getAll(req: Request) async throws -> [Sponsor] {
        try await SponsorSupport.all(on: req.db)
    }

    func getSponsors(req: Request) async throws -> [Sponsor] {
        try await SponsorSupport.all(type: .sponsor, on: req.db)
    }

    func getPartners(req: Request) async throws -> [Sponsor] {
        try await SponsorSupport.all(type: .partner, on: req.db)
    }
}

enum SponsorSupport {
    static func all(on database: Database) async throws -> [Sponsor] {
        try await Sponsor.query(on: database)
            .sort(\.$position, .ascending)
            .sort(\.$created, .ascending)
            .all()
    }

    static func all(type: SponsorType, on database: Database) async throws -> [Sponsor] {
        try await Sponsor.query(on: database)
            .filter(\.$type == type)
            .sort(\.$position, .ascending)
            .sort(\.$created, .ascending)
            .all()
    }

    static func normalizedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Name must not be empty.")
        }
        return name
    }

    static func validatedURL(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw Abort(.badRequest, reason: "\(field) must be a valid HTTP or HTTPS URL.")
        }
        return trimmed
    }

    static func persistCanonicalOrder(_ items: [Sponsor], on database: Database) async throws {
        for (index, item) in items.enumerated() {
            let expected = index + 1
            if item.position != expected {
                item.position = expected
                try await item.update(on: database)
            }
        }
    }
}
