//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class SeasonController: RouteCollection {
    let repository: StandardControllerRepository<Season>

    init(path: String) {
        self.repository = StandardControllerRepository<Season>(path: path)
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
        // Add the new route to delete a season with its matches
        route.delete("matches", ":id", use: deleteSeasonWithMatches)
        route.get(":id", "matches", use: getSeasonWithMatches)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func deleteSeasonWithMatches(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let seasonID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing season ID"))
        }

        return Season.query(on: req.db)
            .filter(\.$id == seasonID)
            .with(\.$matches)
            .first()
            .unwrap(or: Abort(.notFound, reason: "Season not found"))
            .flatMap { season in
                return season.$matches.query(on: req.db).all().flatMap { matches in
                    let deleteMatches = matches.delete(on: req.db)
                    let deleteSeason = season.delete(on: req.db)
                    return deleteMatches.and(deleteSeason).transform(to: .ok)
                }
            }
    }
    
    func getSeasonWithMatches(req: Request) throws -> EventLoopFuture<Season> {
        guard let seasonID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Season.query(on: req.db)
            .filter(\.$id == seasonID)
            .with(\.$matches)
            .first()
            .unwrap(or: Abort(.notFound))
    }

}

extension Season: Mergeable {
    func merge(from other: Season) -> Season {
        var merged = self
        merged.id = other.id
        merged.league?.id = other.league?.id
        merged.name = other.name
        merged.details = other.details
        merged.matches = other.matches
        return merged
    }
}
