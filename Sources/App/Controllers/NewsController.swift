//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class NewsController: RouteCollection {
    let repository: StandardControllerRepository<NewsItem>

    init(path: String) {
        self.repository = StandardControllerRepository<NewsItem>(path: path)
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
    
        route.get("all", use: getAllExceptStrafsenat)
        route.get("strafsenat", use: getAllWithStrafsenat)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func getAllExceptStrafsenat(req: Request) throws -> EventLoopFuture<[NewsItem]> {
        return NewsItem.query(on: req.db)
            .filter(\.$tag != "strafsenat")
            .all()
    }

    func getAllWithStrafsenat(req: Request) throws -> EventLoopFuture<[NewsItem]> {
        return NewsItem.query(on: req.db)
            .filter(\.$tag == "strafsenat")
            .all()
    }

}

