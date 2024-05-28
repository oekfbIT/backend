//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
 
final class PlayerController: RouteCollection {
    let repository: StandardControllerRepository<Player>

    init(path: String) {
        self.repository = StandardControllerRepository<Player>(path: path)
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

extension Player: Mergeable {
    func merge(from other: Player) -> Player {
        var merged = self
        merged.id = other.id
        merged.sid = other.sid
        merged.name = other.name
        merged.number = other.number
        merged.birthday = other.birthday
        merged.team = other.team
        merged.nationality = other.nationality
        merged.position = other.position
        merged.eligibility = other.eligibility
        merged.registerDate = other.registerDate
        merged.matchesPlayed = other.matchesPlayed
        merged.goals = other.goals
        return merged
    }
}
