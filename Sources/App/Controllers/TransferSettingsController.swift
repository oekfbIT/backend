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

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        
        // Add the new routes
        route.get("settings", use: getFirstSettings)
        route.get("toggle", use: toggleIsTransferOpen)
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
}
