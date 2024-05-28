//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor

final class MatchController: RouteCollection {
    let repository: StandardControllerRepository<Match>

    init(path: String) {
        self.repository = StandardControllerRepository<Match>(path: path)
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
        
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}

extension Match: Mergeable {
    func merge(from other: Match) -> Match {
        var merged = self
        merged.id = other.id
        merged.details = other.details
        merged.actualGameStart = other.actualGameStart
        merged.currentHalf = other.currentHalf
        merged.score = other.score
        merged.bericht = other.bericht
        merged.referee = other.referee
        merged.season = other.season
        merged.events = other.events
        return merged
    }
}
