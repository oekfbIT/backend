
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

        route.patch(":id", use: repository.updateID)
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
    
    func register(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let registrationRequest = try req.content.decode(TeamRegistrationRequest.self)

        print(registrationRequest)
        
        let newRegistration = TeamRegistration()
        newRegistration.primary = registrationRequest.primaryContact
        newRegistration.secondary = registrationRequest.secondaryContact
        newRegistration.teamName = registrationRequest.teamName
        newRegistration.verein = registrationRequest.verein
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.status = .draft
        newRegistration.paidAmount = nil
        newRegistration.bundesland = registrationRequest.bundesland
        newRegistration.initialPassword = registrationRequest.initialPassword ?? String.randomString(length: 8)
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.customerSignedContract = nil
        newRegistration.adminSignedContract = nil
        newRegistration.paidAmount = 0.0
        newRegistration.isWelcomeEmailSent = true
        newRegistration.isLoginDataSent = false
        
        return newRegistration.save(on: req.db).map { _ in
            // Send the welcome email in the background
            print("Created: ", newRegistration)
            self.sendWelcomeEmailInBackground(req: req, recipient: registrationRequest.primaryContact.email, registration: newRegistration)
            return HTTPStatus.ok
        }.flatMapError { error in
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid request"))
        }
    }

    // Background email sending function
    private func sendWelcomeEmailInBackground(req: Request, recipient: String, registration: TeamRegistration?) {
        // Run the email sending on the request's event loop
        req.eventLoop.execute {
            do {
                try emailController.sendWelcomeMail(req: req, recipient: recipient, registration: registration).whenComplete { result in
                    switch result {
                    case .success:
                        print("Welcome email sent successfully to \(recipient)")
                    case .failure(let error):
                        print("Failed to send welcome email to \(recipient): \(error)")
                    }
                }
            } catch {
                print("Failed to initiate sending welcome email to \(recipient): \(error)")
            }
        }
    }

    // Confirm
    func confirm(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)
        return TeamRegistration.find(id, on: req.db).unwrap(or: Abort(.notFound)).flatMap { registration in
            registration.status = .approved
            return registration.save(on: req.db).transform(to: .ok)
        }
    }

    // Reject
    func reject(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)
        return TeamRegistration.find(id, on: req.db).unwrap(or: Abort(.notFound)).flatMap { registration in
            registration.status = .rejected
            return registration.save(on: req.db).transform(to: .ok)
        }
    }
    
    func assignLeague(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let registrationID = try req.parameters.require("id", as: UUID.self)
        let leagueID = try req.parameters.require("leagueid", as: UUID.self)

        return TeamRegistration.find(registrationID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { registration in
                return League.find(leagueID, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { league in
                        return Team.query(on: req.db)
                            .filter(\.$league.$id == leagueID)
                            .count()
                            .flatMap { numberOfTeams in
                                let topayAmount = (numberOfTeams - 1) * 70
                                registration.assignedLeague = leagueID
                                if let currentPaidAmount = registration.paidAmount {
                                    registration.paidAmount = currentPaidAmount - Double(topayAmount)
                                } else {
                                    registration.paidAmount = -Double(topayAmount)
                                }
                                return registration.save(on: req.db).transform(to: .ok)
                            }
                    }
            }
    }


    // Update Payment Confirmation
    func updatePaymentConfirmation(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)
        let paymentRequest = try req.content.decode(UpdatePaymentRequest.self)
        return TeamRegistration.find(id, on: req.db).unwrap(or: Abort(.notFound)).flatMap { registration in
            if let currentPaidAmount = registration.paidAmount {
                registration.paidAmount = currentPaidAmount + paymentRequest.paidAmount
            } else {
                registration.paidAmount = paymentRequest.paidAmount
            }
            return registration.save(on: req.db).transform(to: .ok)
        }
    }

    func startTeamCustomization(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)
        return TeamRegistration.find(id, on: req.db).flatMap { optionalRegistration in
            if let registration = optionalRegistration {
                let primary = registration.primary
                
                let password = String.randomString(length: 8)
                
                let user = User(
                    userID: UUID().uuidString,
                    type: .team,
                    firstName: primary?.first ?? "",
                    lastName: primary?.last ?? "",
                    email: primary?.email ?? "",
                    passwordHash: try! Bcrypt.hash(password)
                )

                return user.save(on: req.db).flatMap {
                    let team = Team(
                        sid: "",
                        userId: try! user.requireID(),
                        leagueId: registration.assignedLeague,
                        leagueCode: registration.assignedLeague?.uuidString,
                        points: 0,
                        coverimg: "",
                        logo: "",
                        teamName: registration.teamName,
                        foundationYear: "",
                        membershipSince: "",
                        averageAge: "",
                        trikot: Trikot(home: Dress(image: "", color: .dark),
                                       away: Dress(image: "", color: .light)), referCode: registration.refereerLink
                    )

                    // MARK: SEND EMAIL WITH THE LOGIN DATA
                    
                    return team.save(on: req.db).map {
                        // Print values for email sending
                        print("User email: \(primary?.email)")
                        print("User password: \(password)")

                        return HTTPStatus.ok
                    }
                }
            } else {
                return req.eventLoop.future(error: Abort(.notFound))
            }
        }
    }
}
