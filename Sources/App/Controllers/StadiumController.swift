//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor

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
        
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}

extension Stadium: Mergeable {
    func merge(from other: Stadium) -> Stadium {
        var merged = self
        merged.id = other.id
        merged.code = other.code
        merged.name = other.name
        merged.address = other.address
        merged.type = other.type
        merged.schuhwerk = other.schuhwerk
        merged.flutlicht = other.flutlicht
        merged.parking = other.parking
        merged.homeTeam = other.homeTeam
        merged.partnerSince = other.partnerSince
        return merged
    }
}
