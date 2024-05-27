//
//  File.swift
//  
//
//  Created by Alon Yakoby on 27.04.24.
//

import Foundation
import Vapor
 
final class RefereeController: RouteCollection {
    let repository: StandardControllerRepository<Referee>

    init(path: String) {
        self.repository = StandardControllerRepository<Referee>(path: path)
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

extension Referee: Mergeable {
    func merge(from other: Referee) -> Referee {
        var merged = self

        return merged
    }
}
