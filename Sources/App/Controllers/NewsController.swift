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

        route.patch(":id", use: updateID)
        route.patch("batch", use: repository.updateBatch)
    
        route.get("all", use: getAllExceptStrafsenat)
        route.get("strafsenat", use: getAllWithStrafsenat)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func updateID(req: Request) throws -> EventLoopFuture<NewsItem> {
        guard let id = req.parameters.get("id", as: NewsItem.IDValue.self) else {
            throw Abort(.badRequest)
        }
        
        let updatedItem = try req.content.decode(NewsItem.self)
        
        return NewsItem.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { existing in
                // Update only provided fields
                if let newText = updatedItem.text { existing.text = newText }
                if let newTitle = updatedItem.title { existing.title = newTitle }
                if let newImage = updatedItem.image { existing.image = newImage }
                if let newTag = updatedItem.tag { existing.tag = newTag }
                
                return existing.update(on: req.db).map { existing }
            }
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

