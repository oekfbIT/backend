import Vapor
import Fluent

let emailController = EmailController()

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

        route.patch(":id", use: AdminController(path: "admin").patchRegistration)
        route.patch("batch", use: repository.updateBatch)
        
        // Additional routes
        route.post("register", use: register)
        route.post("confirm", ":id", use: confirm)
        route.post("assign", ":id", "league", ":leagueid", use: assignLeague)
        route.post("reject", ":id", use: reject)
        route.post("updatePayment", ":id", use: updatePaymentConfirmation)
        route.post("completeRegistration", ":id", use: startTeamCustomization)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // MARK: - Register
    func register(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TeamRegistrationRequest.self)
        guard input.acceptedAGB, !input.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Mannschaftsname und Zustimmung zu den AGB sind erforderlich.")
        }
        try RegistrationFlow.validateContact(input.primaryContact)
        try RegistrationFlow.validateContact(input.secondaryContact)
        let name = input.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = input.primaryContact.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = try await TeamRegistration.query(on: req.db)
            .filter(\.$teamName == name).filter(\.$bundesland == input.bundesland)
            .filter(\.$status != .rejected).filter(\.$status != .completed).all()
        if candidates.contains(where: { $0.primary?.email.lowercased() == email }) {
            // A retry of the same initial request must not create another registration.
            return .ok
        }
        var primary = input.primaryContact
        primary.email = email; primary.identification = nil
        var secondary = input.secondaryContact
        secondary.email = secondary.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        secondary.identification = nil
        let registration = TeamRegistration(primary: primary, secondary: secondary, verein: input.verein,
            teamName: name, status: .draft, bundesland: input.bundesland,
            initialPassword: String.randomString(length: 20), refereerLink: input.referCode,
            teamLogo: nil, isWelcomeEmailSent: false, isLoginDataSent: false)
        try await registration.save(on: req.db)
        // Keep the request if SMTP fails; the admin overview exposes delivery and retry.
        _ = try? await RegistrationFlow.sendWelcome(req: req, registration: registration).get()
        return .ok
    }

    // MARK: - Confirm
    func confirm(req: Request) async throws -> HTTPStatus {
        try await AdminController(path: "admin").confirm(req: req)
    }

    func findLeague(id: UUID, req: Request) -> EventLoopFuture<League> {
        return League.find(id, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League with ID \(id) not found"))
    }

    // MARK: - Reject
    func reject(req: Request) async throws -> HTTPStatus {
        try await AdminController(path: "admin").reject(req: req)
    }
    
    // MARK: - Assign League
    func assignLeague(req: Request) async throws -> HTTPStatus {
        try await AdminController(path: "admin").assignLeague(req: req)
    }
    // MARK: - Update Payment Confirmation
    func updatePaymentConfirmation(req: Request) async throws -> HTTPStatus {
        try await AdminController(path: "admin").updatePaymentConfirmation(req: req)
    }
    // MARK: - Complete Registration
    func startTeamCustomization(req: Request) async throws -> HTTPStatus {
        try await AdminController(path: "admin").startTeamCustomization(req: req)
    }
}

extension Date {
    var yearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: self)
    }
}
