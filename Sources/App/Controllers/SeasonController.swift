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
        route.post("togglePrimary", ":id", use: togglePrimary)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    // MARK: - Toggle Primary
    func togglePrimary(req: Request) -> EventLoopFuture<Season> {
        guard let seasonID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(
                Abort(.badRequest, reason: "Missing season ID")
            )
        }

        return req.db.transaction { db in
            Season.find(seasonID, on: db)
                .unwrap(or: Abort(.notFound, reason: "Season not found"))
                .flatMap { season in
                    guard let leagueID = season.$league.id else {
                        return req.eventLoop.makeFailedFuture(
                            Abort(.badRequest, reason: "Season is not associated with a league")
                        )
                    }

                    // 1. Set this season as primary
                    season.primary = true

                    return season.save(on: db).flatMap {
                        // 2. Set all other seasons in the same league to false
                        Season.query(on: db)
                            .filter(\.$league.$id == leagueID)
                            .filter(\.$id != seasonID)
                            .set(\.$primary, to: false)
                            .update()
                            .transform(to: season)
                    }
                }
        }
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
