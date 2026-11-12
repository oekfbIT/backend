import Vapor

final class RechnungsController: RouteCollection {
    let repository: StandardControllerRepository<Rechnung>

    init(path: String) {
        self.repository = StandardControllerRepository<Rechnung>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
            .grouped(Token.authenticator(), User.guardMiddleware(), AdminOnlyMiddleware())
        let readable = route.grouped(PermissionMiddleware(.financesRead))
        let manageable = route.grouped(PermissionMiddleware(.financesManage))
        
        manageable.post(use: create)
        manageable.post("batch", use: repository.createBatch)

        readable.get(use: repository.index)
        readable.get(":id", use: repository.getbyID)
        
        manageable.get("complete", ":id", use: complete)
        manageable.delete(":id", use: repository.deleteID)

        manageable.patch(":id", use: repository.updateID)
        manageable.patch("batch", use: repository.updateBatch)
        manageable.get("refund", ":id", use: refund)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
        
    func refund(req: Request) async throws -> HTTPStatus {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let invoice = try await Rechnung.find(id, on: req.db) else { return .ok }
        try invoice.requireManualEntry()
        guard let teamID = invoice.$team.id else { throw Abort(.badRequest) }
        _ = try await TeamBookingStore(database: req.db).apply(
            teamID: teamID, key: "refund-\(id.uuidString.lowercased())") { stored in
                ["balance": try TeamBookingStore.balance(stored) + invoice.refundDelta]
            }
        try await invoice.delete(on: req.db)
        return .ok
    }

    func create(req: Request) throws -> EventLoopFuture<Rechnung> {
        // Decode the incoming Rechnung from the request body
        let rechnung = try req.content.decode(Rechnung.self)
        try rechnung.requireManualEntry()
        rechnung.paymentSource = "manual"
        
        // Fetch the associated team
        return Team.find(rechnung.$team.id, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))
            .flatMap { team in
                team.balance = (team.balance ?? 0) + rechnung.summ
                print(team.balance)
                
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
                do { try rechnung.requireManualEntry() }
                catch { return req.eventLoop.makeFailedFuture(error) }
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
