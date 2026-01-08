//
//  AppController+TransferSettings.swift
//  oekfbbackend
//
//  Mirrors TransferSettingsController routes under /app/transferSettings/...
//

import Foundation
import Vapor
import Fluent

// MARK: - TransferSettings Endpoints (App)
extension AppController {

    /// Call this from your AppController route setup (where you call setupTransferRoutes)
    /// e.g. in AppController.setupRoutes(on:) or similar:
    /// setupTransferSettingsRoutes(on: appGroupedUnderAppPrefix)
    func setupTransferSettingsRoutes(on root: RoutesBuilder) {
        let settings = root.grouped("transferSettings")

        // Mirrors old controller:
        // GET /transferSettings/settings
        settings.get("settings", use: getFirstTransferSettings)

        // GET /transferSettings/toggle
        settings.get("toggle", use: toggleIsTransferOpen)

        // GET /transferSettings/isDressChangeOpen
        settings.get("isDressChangeOpen", use: isDressChangeOpen)

        // GET /transferSettings/isCancelPossible
        settings.get("isCancelPossible", use: isCancelPossible)
    }

    // MARK: - GET /app/transferSettings/settings
    func getFirstTransferSettings(req: Request) async throws -> TransferSettings {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }
        return settings
    }

    // MARK: - GET /app/transferSettings/toggle
    func toggleIsTransferOpen(req: Request) async throws -> TransferSettings {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }

        settings.isTransferOpen.toggle()
        try await settings.save(on: req.db)
        return settings
    }

    // MARK: - GET /app/transferSettings/isDressChangeOpen
    func isDressChangeOpen(req: Request) async throws -> Bool {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }
        return settings.isDressChangeOpen
    }

    // MARK: - GET /app/transferSettings/isCancelPossible
    func isCancelPossible(req: Request) async throws -> Bool {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }
        return settings.isCancelPossible
    }
}
