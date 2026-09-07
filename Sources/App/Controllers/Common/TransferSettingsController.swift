//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor

final class TransferSettingsController: RouteCollection {
    let repository: StandardControllerRepository<TransferSettings>

    init(path: String) {
        self.repository = StandardControllerRepository<TransferSettings>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: updateSettings)
        route.patch("batch", use: repository.updateBatch)
        
        // Add the new routes
        route.get("settings", use: getFirstSettings)
        route.get("toggle", use: toggleIsTransferOpen)
        
        route.get("isDressChangeOpen", use: isDressChangeOpen)
        route.get("isCancelPossible", use: isCancelPossible)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // New method to return the first TransferSettings item
    func getFirstSettings(req: Request) async throws -> TransferSettings {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }
        return settings
    }

    // New method to toggle the isTransferOpen value of the first item
    func toggleIsTransferOpen(req: Request) async throws -> TransferSettings {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }

        settings.isTransferOpen.toggle()
        try await settings.save(on: req.db)
        return settings
    }

    private struct UpdateTransferSettingsRequest: Content {
        let isTransferOpen: Bool?
        let isDressChangeOpen: Bool?
        let isCancelPossible: Bool?
        let showSponsors: Bool?
        let fromDate: String?
        let to: String?
        let name: String?
        let minAppVersion: String?
    }

    func updateSettings(req: Request) async throws -> TransferSettings {
        guard let id = req.parameters.get("id", as: UUID.self),
              let settings = try await TransferSettings.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "TransferSettings not found.")
        }

        let update = try req.content.decode(UpdateTransferSettingsRequest.self)

        if let value = update.isTransferOpen { settings.isTransferOpen = value }
        if let value = update.isDressChangeOpen { settings.isDressChangeOpen = value }
        if let value = update.isCancelPossible { settings.isCancelPossible = value }
        if let value = update.showSponsors { settings.showSponsors = value }
        if let value = update.fromDate { settings.fromDate = value }
        if let value = update.to { settings.to = value }
        if let value = update.name { settings.name = value }
        if let value = update.minAppVersion { settings.minAppVersion = value }

        try await settings.save(on: req.db)
        return settings
    }
    
    // New method to return true or false if the dress change is open
    func isDressChangeOpen(req: Request) async throws -> Bool {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }
        return settings.isDressChangeOpen
    }

    // New method to return true or false if the dress change is open
    func isCancelPossible(req: Request) async throws -> Bool {
        guard let settings = try await TransferSettings.query(on: req.db).first() else {
            throw Abort(.notFound, reason: "No TransferSettings found.")
        }
        return settings.isCancelPossible
    }

}
