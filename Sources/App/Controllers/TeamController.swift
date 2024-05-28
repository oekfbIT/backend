//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor

final class TeamController: RouteCollection {
    let repository: StandardControllerRepository<Team>

    init(path: String) {
        self.repository = StandardControllerRepository<Team>(path: path)
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

extension Team: Mergeable {
    func merge(from other: Team) -> Team {
        var merged = self
        merged.id = other.id
        merged.points = other.points
        merged.logo = other.logo
        merged.teamName = other.teamName
        merged.foundationYear = other.foundationYear
        merged.membershipSince = other.membershipSince
        merged.averageAge = other.averageAge
        merged.coachName = other.coachName
        merged.captain = other.captain
        merged.trikot = other.trikot
        merged.balance = other.balance
        return merged
    }
}
