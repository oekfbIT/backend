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
            print("Created: ", newRegistration)
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

    private func sendTeamLogin(req: Request, recipient: String, email: String, password: String) {
        req.eventLoop.execute {
            do {
                try emailController
                    .sendTeamLogin(req: req, recipient: recipient, email: email, password: password)
                    .whenComplete { result in
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

    // MARK: - Confirm
    func confirm(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let id = try req.parameters.require("id", as: UUID.self)

        return TeamRegistration.find(id, on: req.db).flatMap { optionalRegistration in
            guard let registration = optionalRegistration else {
                return req.eventLoop.makeFailedFuture(Abort(.notFound))
            }

            registration.status = .approved

            // Ensure initialPassword exists for email payload (your current flow expects it)
            let passwordForEmail = registration.initialPassword ?? String.randomString(length: 8)
            if registration.initialPassword == nil {
                registration.initialPassword = passwordForEmail
            }

            return self.resolveUser(for: registration, on: req).flatMap { user in
                // If user was newly created and registration.user is still nil, attach it
                if registration.user == nil, let uid = user.id {
                    registration.user = uid
                }

                // IMPORTANT: email triggers go to the USER email (primary & user can differ)
                let recipientEmail = user.email

                return self.findLeague(id: registration.assignedLeague!, req: req).flatMap { league in
                    // Save registration first to persist status/user/password changes
                    return registration.save(on: req.db).flatMap {
                        let team = Team(
                            sid: String.randomNum(length: 5),
                            userId: user.id,
                            leagueId: registration.assignedLeague,
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
                            usrpass: registration.initialPassword,
                            usrtel: registration.primary?.phone,
                            kaution: registration.kaution
                        )

                        print("Team to be saved: \(team)")

                        return team.save(on: req.db).flatMap {
                            self.sendTeamLogin(
                                req: req,
                                recipient: recipientEmail,
                                email: recipientEmail,
                                password: passwordForEmail
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
                        switch teamCount {
                        case 0...6:
                            topayAmount = Double((teamCount - 1) * 2) * 70.0
                        case 7...9:
                            topayAmount = Double(teamCount - 1) * 1.5 * 70.0
                        case 10...:
                            topayAmount = Double(teamCount - 1) * 70.0
                        default:
                            topayAmount = 0.0
                        }

                        registration.assignedLeague = leagueID
                        registration.kaution = 300.00
                        if let currentPaidAmount = registration.paidAmount {
                            registration.paidAmount = currentPaidAmount - topayAmount
                        } else {
                            registration.paidAmount = -(topayAmount + (registration.kaution ?? 0))
                        }

                        let primaryContactEmail = registration.primary?.email
                        self.sendPaymentInstructionsInBackground(
                            req: req,
                            recipient: primaryContactEmail ?? "",
                            registration: registration
                        )
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
                            print("Payment instructions email sent successfully to \(recipient)")
                        case .failure(let error):
                            print("Failed to send payment instructions email to \(recipient): \(error)")
                        }
                    }
            } catch {
                print("Failed to initiate sending payment instructions email to \(recipient): \(error)")
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
                if let currentPaidAmount = registration.paidAmount {
                    registration.paidAmount = currentPaidAmount + paymentRequest.paidAmount
                } else {
                    registration.paidAmount = paymentRequest.paidAmount
                }
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

            // Ensure initialPassword exists for debug/email payload consistency
            let passwordForEmail = registration.initialPassword ?? String.randomString(length: 8)
            if registration.initialPassword == nil {
                registration.initialPassword = passwordForEmail
            }

            return self.resolveUser(for: registration, on: req).flatMap { user in
                // If user was newly created and registration.user is still nil, attach it
                if registration.user == nil, let uid = user.id {
                    registration.user = uid
                }

                // IMPORTANT: email triggers should use USER email (primary & user can differ)
                let recipientEmail = user.email

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
                    coach: Trainer(name: "", email: "", image: ""),
                    trikot: Trikot(home: "", away: ""),
                    referCode: registration.refereerLink,
                    usremail: registration.primary?.email,
                    usrpass: registration.initialPassword,
                    usrtel: registration.primary?.phone
                )

                return registration.save(on: req.db).flatMap {
                    return team.save(on: req.db).map {
                        print("User email: \(recipientEmail)")
                        print("User password: \(passwordForEmail)")
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
