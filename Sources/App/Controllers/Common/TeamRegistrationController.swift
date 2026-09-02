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

    // MARK: - User Resolution
    // Rule:
    // - If registration.user exists -> use that user, DO NOT create a new one.
    // - Else create a new user from primary contact.
    private func resolveUser(for registration: TeamRegistration, on req: Request) -> EventLoopFuture<User> {
        if let attachedUserId = registration.user {
            return User.find(attachedUserId, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Attached user not found"))
        }

        let primaryEmail = (registration.primary?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primaryEmail.isEmpty else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Primary contact email is missing"))
        }

        // Ensure we have a stable password (used for newly created user + email)
        let password = registration.initialPassword ?? String.randomString(length: 8)
        if registration.initialPassword == nil {
            registration.initialPassword = password
        }

        let userSignup = UserSignup(
            id: String.randomString(length: 5),
            firstName: registration.primary?.first ?? "",
            lastName: registration.primary?.last ?? "",
            email: primaryEmail,
            password: password,
            type: .team,
            tel: registration.primary?.phone
        )

        do {
            let user = try User.create(from: userSignup)
            return user.save(on: req.db).map { user }
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
    }

    // MARK: - Register
    func register(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let registrationRequest = try req.content.decode(TeamRegistrationRequest.self)

        req.logger.debug("Creating team registration")
        
        let newRegistration = TeamRegistration()
        newRegistration.primary = registrationRequest.primaryContact
        newRegistration.secondary = registrationRequest.secondaryContact
        newRegistration.teamName = registrationRequest.teamName
        newRegistration.verein = registrationRequest.verein
        newRegistration.status = .draft
        newRegistration.bundesland = registrationRequest.bundesland
        newRegistration.initialPassword = registrationRequest.initialPassword ?? String.randomString(length: 8)
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.customerSignedContract = nil
        newRegistration.adminSignedContract = nil

        // Keep this nil until league assignment calculates the real amount
        newRegistration.paidAmount = nil

        newRegistration.isWelcomeEmailSent = true
        newRegistration.isLoginDataSent = false
        
        return newRegistration.save(on: req.db).map { _ in
            req.logger.info("Created team registration \(registrationRequest.teamName)")
            self.sendWelcomeEmailInBackground(
                req: req,
                recipient: registrationRequest.primaryContact.email,
                registration: newRegistration
            )
            return HTTPStatus.ok
        }.flatMapError { _ in
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid request"))
        }
    }
    
    // MARK: - Email Helpers
    private func sendWelcomeEmailInBackground(req: Request, recipient: String, registration: TeamRegistration?) {
        req.eventLoop.execute {
            do {
                try emailController
                    .sendWelcomeMail(req: req, recipient: recipient, registration: registration)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            req.logger.debug("Welcome email sent successfully")
                        case .failure(let error):
                            req.logger.error("Welcome email failed: \(error)")
                        }
                    }
            } catch {
                req.logger.error("Failed to queue welcome email: \(error)")
            }
        }
    }

    private func sendTeamLogin(req: Request, recipient: String, email: String, password: String) {
        req.eventLoop.execute {
            do {
                try emailController
                    .sendTeamLogin(req: req, recipient: recipient, email: email, password: password)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            req.logger.debug("Team login email sent successfully")
                        case .failure(let error):
                            req.logger.error("Team login email failed: \(error)")
                        }
                    }
            } catch {
                req.logger.error("Failed to queue team login email: \(error)")
            }
        }
    }

    // MARK: - Confirm
    func confirm(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)

        return TeamRegistration.find(id, on: req.db).flatMap { optionalRegistration in
            guard let registration = optionalRegistration else {
                return req.eventLoop.makeFailedFuture(Abort(.notFound))
            }

            return self.resolveUser(for: registration, on: req).flatMap { user in
                guard let assignedLeague = registration.assignedLeague else {
                    return req.eventLoop.makeFailedFuture(Abort(.preconditionFailed, reason: "Registration has no assigned league"))
                }
                guard let userID = try? user.requireID() else {
                    return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "User id is unavailable"))
                }
                // If user was newly created and registration.user is still nil, attach it
                if registration.user == nil {
                    registration.user = userID
                }
                let userEmail = user.email
                let initialPassword = registration.initialPassword ?? String.randomString(length: 8)
                registration.initialPassword = initialPassword
                
                return self.findLeague(id: assignedLeague, req: req).flatMap { league in
                    let team = Team(
                        sid: String.randomNum(length: 5),
                        userId: userID,
                        leagueId: assignedLeague,
                        leagueCode: league.code,
                        points: 0,
                        coverimg: "",
                        logo: registration.teamLogo ?? "",
                        teamName: registration.teamName,
                        foundationYear: Date.viennaNow.yearString,
                        membershipSince: Date.viennaNow.yearString,
                        averageAge: "0",
                        coach: Trainer(name: "", email: "", image: ""),
                        trikot: Trikot(home: "", away: ""),
                        balance: registration.paidAmount ?? 0.0,
                        usremail: registration.primary?.email,
                        usrpass: initialPassword,
                        usrtel: registration.primary?.phone,
                        kaution: registration.kaution
                    )

                    registration.status = .approved

                    return registration.save(on: req.db).flatMap {
                        team.save(on: req.db).flatMap {
                            self.sendTeamLogin(
                                req: req,
                                recipient: userEmail,
                                email: userEmail,
                                password: initialPassword
                            )
                            return registration.save(on: req.db).transform(to: .ok)
                        }
                    }
                }
            }
        }
    }

    func findLeague(id: UUID, req: Request) -> EventLoopFuture<League> {
        return League.find(id, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League with ID \(id) not found"))
    }

    // MARK: - Reject
    func reject(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)
        return TeamRegistration.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { registration in
                registration.status = .rejected
                return registration.save(on: req.db).transform(to: .ok)
            }
    }
    
    // MARK: - Assign League
    func assignLeague(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let registrationID = try req.parameters.require("id", as: UUID.self)
        let leagueID = try req.parameters.require("leagueid", as: UUID.self)

        return TeamRegistration.find(registrationID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { registration in
                return League.find(leagueID, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { league in
                        let teamCount = league.teamcount ?? 0
                        let topayAmount: Double
                        let teamPrice = 80.0

                        switch teamCount {
                        case 0...6:
                            topayAmount = Double(teamCount - 1) * 2.0 * teamPrice
                        case 7...9:
                            topayAmount = Double(teamCount - 1) * 1.5 * teamPrice
                        case 10...:
                            topayAmount = Double(teamCount - 1) * teamPrice
                        default:
                            topayAmount = 0.0
                        }

                        registration.assignedLeague = leagueID
                        registration.kaution = 300.00

                        // Always recalculate from scratch
                        registration.paidAmount = -(topayAmount + (registration.kaution ?? 0.0))

                        let registrationID = registration.id?.uuidString ?? "missing-id"
                        req.logger.debug("Assign league calculation for registration \(registrationID)")
                        req.logger.debug("teamCount: \(teamCount)")
                        req.logger.debug("teamPrice: \(teamPrice)")
                        req.logger.debug("topayAmount: \(topayAmount)")
                        req.logger.debug("kaution: \(registration.kaution ?? 0.0)")
                        req.logger.debug("paidAmount: \(registration.paidAmount ?? 0.0)")

                        if let primaryContactEmail = registration.primary?.email, !primaryContactEmail.isEmpty {
                            self.sendPaymentInstructionsInBackground(
                                req: req,
                                recipient: primaryContactEmail,
                                registration: registration
                            )
                        }

                        return registration.save(on: req.db).transform(to: .ok)
                    }
            }
    }
    private func sendPaymentInstructionsInBackground(req: Request, recipient: String, registration: TeamRegistration) {
        req.eventLoop.execute {
            do {
                try emailController
                    .sendPaymentMail(req: req, recipient: recipient, registration: registration)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            req.logger.debug("Payment instructions email sent successfully")
                        case .failure(let error):
                            req.logger.error("Payment instructions email failed: \(error)")
                        }
                    }
            } catch {
                req.logger.error("Failed to queue payment instructions: \(error)")
            }
        }
    }

    // MARK: - Update Payment Confirmation
    func updatePaymentConfirmation(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)
        let paymentRequest = try req.content.decode(UpdatePaymentRequest.self)

        return TeamRegistration.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { registration in
                let currentPaidAmount = registration.paidAmount ?? 0.0
                registration.paidAmount = currentPaidAmount + paymentRequest.paidAmount

                return registration.save(on: req.db).transform(to: .ok)
            }
    }
    // MARK: - Complete Registration
    func startTeamCustomization(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)

        return TeamRegistration.find(id, on: req.db).flatMap { optionalRegistration in
            guard let registration = optionalRegistration else {
                return req.eventLoop.future(error: Abort(.notFound))
            }

            return self.resolveUser(for: registration, on: req).flatMap { user in
                guard let userID = try? user.requireID() else {
                    return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "User id is unavailable"))
                }
                // If user was newly created and registration.user is still nil, attach it
                if registration.user == nil {
                    registration.user = userID
                }

                let team = Team(
                    sid: "",
                    userId: userID,
                    leagueId: registration.assignedLeague,
                    leagueCode: registration.assignedLeague?.uuidString,
                    points: 0,
                    coverimg: "",
                    logo: "",
                    teamName: registration.teamName,
                    foundationYear: "",
                    membershipSince: "",
                    averageAge: "",
                    coach: Trainer(name: "", email: "", image: ""),
                    trikot: Trikot(home: "", away: ""),
                    referCode: registration.refereerLink,
                    usremail: registration.primary?.email,
                    usrpass: registration.initialPassword,
                    usrtel: registration.primary?.phone
                )

                return registration.save(on: req.db).flatMap {
                    return team.save(on: req.db).map {
                        req.logger.info("Team created for user \(userID)")
                        return HTTPStatus.ok
                    }
                }
            }
        }
    }
}

extension Date {
    var yearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: self)
    }
}
