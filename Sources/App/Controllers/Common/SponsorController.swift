//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class SponsorController: RouteCollection {
    let repository: StandardControllerRepository<Sponsor>

    init(path: String) {
        self.repository = StandardControllerRepository<Sponsor>(path: path)
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
        
        route.get("sponsors", use: getAllSponsors)
        route.get("partners", use: getAllPartners)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func getAllSponsors(req: Request) throws -> EventLoopFuture<[Sponsor]> {
        return Sponsor.query(on: req.db)
            .filter(\Sponsor.$type == .sponsor)
            .all()
    }

    func getAllPartners(req: Request) throws -> EventLoopFuture<[Sponsor]> {
        return Sponsor.query(on: req.db)
            .filter(\Sponsor.$type == .partner)
            .all()
    }

}

