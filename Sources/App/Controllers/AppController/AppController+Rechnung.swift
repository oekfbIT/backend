//
//  AppController+Rechnung.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 11.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - AppController Rechnungen (Invoices) Endpoints
//
// Routes:
//   GET /app/rechnungen/team/:teamID      -> getRechnungenByTeamID
//   GET /app/rechnungen/:rechnungID      -> getRechnungDetailByID
//

extension AppController {
    func setupInvoiceRoutes(on root: RoutesBuilder) {
        let rechnungen = root.grouped("rechnungen")

        rechnungen.get("team", ":teamID", use: getRechnungenByTeamID)
        rechnungen.get(":rechnungID", use: getRechnungDetailByID)
    }

    // GET /app/rechnungen/team/:teamID
    /// Returns all invoices for the team, newest first.
    func getRechnungenByTeamID(req: Request) async throws -> [Rechnung] {
        let teamID = try req.parameters.require("teamID", as: UUID.self)

        // Optional: explicit 404 if team doesn't exist
        guard try await Team.find(teamID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        let rechnungen = try await Rechnung.query(on: req.db)
            .filter(\.$team.$id == teamID)
            .sort(\.$created, .descending)
            .all()

        return rechnungen
    }

    // GET /app/rechnungen/:rechnungID
    /// Returns a single invoice by its ID.
    func getRechnungDetailByID(req: Request) async throws -> Rechnung {
        let rechnungID = try req.parameters.require("rechnungID", as: UUID.self)

        guard let rechnung = try await Rechnung.find(rechnungID, on: req.db) else {
            throw Abort(.notFound, reason: "Rechnung not found.")
        }

        return rechnung
    }
}
