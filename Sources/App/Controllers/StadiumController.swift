//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Vapor
import Fluent

final class StadiumController: RouteCollection {
    let repository: StandardControllerRepository<Stadium>

    init(path: String) {
        self.repository = StandardControllerRepository<Stadium>(path: path)
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
        
        // New route for getting stadiums by bundesland
        route.get("bundesland", ":bundesland", use: getStadiumsByBundesland)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    func getStadiumsByBundesland(req: Request) -> EventLoopFuture<[Stadium]> {
        guard let bundeslandString = req.parameters.get("bundesland"),
              let bundesland = Bundesland(bundeslandString) else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing bundesland parameter"))
        }

        return Stadium.query(on: req.db)
            .filter(\.$bundesland == bundesland)
            .all()
    }
}
