//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 18.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - Sponsor Endpoints
extension AppController {

    func setupSponsorRoutes(on root: RoutesBuilder) {
        let sponsor = root.grouped("sponsor")

        sponsor.get("sponsors", use: getAllSponsors)
        sponsor.get("partners", use: getAllPartners)
        sponsor.get("all", use: getAllSponsorEntries)
    }

    /// GET /app/sponsor/sponsors
    func getAllSponsors(req: Request) async throws -> [Sponsor] {
        try await Sponsor.query(on: req.db)
            .filter(\.$type == .sponsor)
            .sort(\.$created, .descending)
            .all()
    }

    /// GET /app/sponsor/partners
    func getAllPartners(req: Request) async throws -> [Sponsor] {
        try await Sponsor.query(on: req.db)
            .filter(\.$type == .partner)
            .sort(\.$created, .descending)
            .all()
    }

    /// GET /app/sponsor/all
    func getAllSponsorEntries(req: Request) async throws -> [Sponsor] {
        try await Sponsor.query(on: req.db)
            .sort(\.$created, .descending)
            .all()
    }
}
