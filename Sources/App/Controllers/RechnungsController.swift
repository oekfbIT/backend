import Vapor

final class RechnungsController: RouteCollection {
    let repository: StandardControllerRepository<Rechnung>

    init(path: String) {
        self.repository = StandardControllerRepository<Rechnung>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.get("complete", ":id", use: complete)  // Add the new route here
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func create(req: Request) throws -> EventLoopFuture<Rechnung> {
        // Decode the incoming Rechnung from the request body
        let rechnung = try req.content.decode(Rechnung.self)
        
        // Fetch the associated team
        return Team.find(rechnung.$team.id, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))
            .flatMap { team in
                // Subtract the summ from the team's balance
                if let currentBalance = team.balance {
                    team.balance = currentBalance - rechnung.summ
                } else {
                    team.balance = -rechnung.summ
                }
                
                // Save the updated team
                return team.save(on: req.db).flatMap {
                    // Save the new Rechnung to the database
                    return rechnung.create(on: req.db).map { rechnung }
                }
            }
    }

    func complete(req: Request) throws -> EventLoopFuture<Rechnung> {
        let id = try req.parameters.require("id", as: UUID.self)
        
        return Rechnung.find(id, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Rechnung not found"))
            .flatMap { rechnung in
                // Update the status to .bezahlt
                rechnung.status = .bezahlt
                
                // Fetch the associated team
                return Team.find(rechnung.$team.id, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Team not found"))
                    .flatMap { team in
                        // Add the sum to the team's balance
                        if let currentBalance = team.balance {
                            team.balance = currentBalance + rechnung.summ
                        } else {
                            team.balance = rechnung.summ
                        }
                        
                        // Save the updated team and Rechnung
                        return team.save(on: req.db).flatMap {
                            return rechnung.save(on: req.db).map { rechnung }
                        }
                    }
            }
    }
}
