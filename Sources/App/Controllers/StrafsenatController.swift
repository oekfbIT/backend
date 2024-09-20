//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class StrafsenatController: RouteCollection {
    let repository: StandardControllerRepository<Strafsenat>

    init(path: String) {
        self.repository = StandardControllerRepository<Strafsenat>(path: path)
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
        
        // Add the close and open routes
        route.patch(":id","close", use: close)
        route.patch(":id","open", use: open)
    }

    // Function to close the status (set offen to false)
    func close(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return Strafsenat.find(req.parameters.get("id"), on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { strafsenat in
                strafsenat.offen = false
                return strafsenat.save(on: req.db).transform(to: .ok)
            }
    }

    // Function to open the status (set offen to true)
    func open(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return Strafsenat.find(req.parameters.get("id"), on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { strafsenat in
                strafsenat.offen = true
                return strafsenat.save(on: req.db).transform(to: .ok)
            }
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}
