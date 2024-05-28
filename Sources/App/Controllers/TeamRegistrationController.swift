
import Vapor

final class TeamRegistrationController: RouteCollection {
    let repository: StandardControllerRepository<TeamRegistration>

    init(path: String) {
        self.repository = StandardControllerRepository<TeamRegistration>(path: path)
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

extension TeamRegistration {
    func merge(from other: TeamRegistration) -> TeamRegistration {
        var merged = self
        merged.id = other.id
        merged.primary = other.primary
        merged.secondary = other.secondary
        merged.verein = other.verein
        merged.teamName = other.teamName
        merged.refereerLink = other.refereerLink
        merged.customerSignedContract = other.customerSignedContract
        merged.adminSignedContract = other.adminSignedContract
        merged.assignedLeague = other.assignedLeague
        merged.paidAmount = other.paidAmount
        merged.user = other.user
        merged.team = other.team
        merged.isWelcomeEmailSent = other.isWelcomeEmailSent
        merged.isLoginDataSent = other.isLoginDataSent
        return merged
    }
}
