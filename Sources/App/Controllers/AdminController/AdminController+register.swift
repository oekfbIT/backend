//
//  AdminController+RegistrationRoutes.swift
//
//  Admin Team Registrations (pattern-matched to your other AdminController extensions)
//
//  Mounted under AdminController authed + AdminOnlyMiddleware() group.
//
//  Endpoints:
//  - GET    /admin/registrations                          -> [TeamRegistration]
//  - GET    /admin/registrations/:id                      -> TeamRegistration
//  - PATCH  /admin/registrations/:id                      -> TeamRegistration   (multipart)
//
//  - POST   /admin/registrations/register                 -> HTTPStatus         (multipart; draft creation + welcome email)
//  - POST   /admin/registrations/confirm/:id              -> HTTPStatus
//  - POST   /admin/registrations/assign/:id/league/:lid   -> HTTPStatus
//  - POST   /admin/registrations/reject/:id               -> HTTPStatus
//  - POST   /admin/registrations/updatePayment/:id        -> HTTPStatus
//  - POST   /admin/registrations/completeRegistration/:id -> HTTPStatus
//
//  Important Fixes:
//  - customerSignedContract/adminSignedContract/teamLogo now support File upload (pdf/image)
//    and are stored as URL strings in DB after Firebase upload.
//  - primary/secondary identification are handled as optional File uploads,
//    and stored into ContactPerson.identification URL.
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Registration Routes
extension AdminController {

    func setupRegistrationRoutes(on root: RoutesBuilder) {
        let regs = root.grouped("registrations")

        // CRUD-ish
        regs.get(use: getAllRegistrations)
        regs.get(":id", use: getRegistrationByID)

        // multipart patch (optional files)
        regs.patch(":id", use: patchRegistration)

        // Actions
        regs.post("register", use: register)
        regs.post("confirm", ":id", use: confirm)
        regs.post("assign", ":id", "league", ":leagueid", use: assignLeague)
        regs.post("reject", ":id", use: reject)
        regs.post("updatePayment", ":id", use: updatePaymentConfirmation)
        regs.post("completeRegistration", ":id", use: startTeamCustomization)
    }
}

// MARK: - DTOs
extension AdminController {

    /// Multipart register payload (supports completed data + files)
    struct TeamRegistrationRequest: Content {
        let primaryContact: ContactPerson
        let secondaryContact: ContactPerson?

        let teamName: String
        let verein: String?
        let bundesland: Bundesland
        let initialPassword: String?
        let referCode: String?

        // NEW: Optional uploads
        let teamLogoFile: File?
        let customerSignedContractFile: File?
        let adminSignedContractFile: File?
        let primaryIdentificationFile: File?
        let secondaryIdentificationFile: File?
    }

    struct UpdatePaymentRequest: Content {
        let paidAmount: Double
    }

    /// Multipart patch payload
    /// - optional URLs (string) are still allowed if you want to set directly
    /// - optional Files will upload to Firebase and overwrite URL fields
    struct PatchTeamRegistrationRequest: Content {
        var primary: ContactPerson?
        var secondary: ContactPerson?

        var verein: String?
        var teamName: String?
        var status: TeamRegistrationStatus?
        var bundesland: Bundesland?

        var initialPassword: String?
        var refereerLink: String?
        var assignedLeague: UUID?

        // URL fields (direct set)
        var customerSignedContract: String?
        var adminSignedContract: String?
        var teamLogo: String?

        // NEW: File uploads (preferred)
        var customerSignedContractFile: File?
        var adminSignedContractFile: File?
        var teamLogoFile: File?

        // NEW: Identification file uploads (writes into ContactPerson.identification)
        var primaryIdentificationFile: File?
        var secondaryIdentificationFile: File?

        var paidAmount: Double?
        var user: UUID?
        var team: UUID?

        var isWelcomeEmailSent: Bool?
        var isLoginDataSent: Bool?
        var dateCreated: Date?

        var kaution: Double?
    }
}

// MARK: - Handlers
extension AdminController {

    // GET /admin/registrations
    func getAllRegistrations(req: Request) async throws -> [TeamRegistration] {
        try await TeamRegistration.query(on: req.db)
            .sort(\.$dateCreated, .descending)
            .all()
    }

    // GET /admin/registrations/:id
    func getRegistrationByID(req: Request) async throws -> TeamRegistration {
        try await requireRegistration(req: req, param: "id")
    }

    // PATCH /admin/registrations/:id  (multipart/form-data)
    func patchRegistration(req: Request) async throws -> TeamRegistration {
        let reg = try await requireRegistration(req: req, param: "id")
        let body = try req.content.decode(PatchTeamRegistrationRequest.self)

        // non-file fields
        if let v = body.primary { reg.primary = v }
        if let v = body.secondary { reg.secondary = v }
        if let v = body.verein { reg.verein = v }

        if let v = body.teamName {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "teamName cannot be empty.") }
            reg.teamName = t
        }

        if let v = body.status { reg.status = v }
        if let v = body.bundesland { reg.bundesland = v }

        if let v = body.initialPassword { reg.initialPassword = v }
        if let v = body.refereerLink { reg.refereerLink = v }
        if let v = body.assignedLeague { reg.assignedLeague = v }

        if let v = body.user { reg.user = v }
        if let v = body.team { reg.team = v }

        if body.paidAmount != nil { reg.paidAmount = body.paidAmount }
        if body.kaution != nil { reg.kaution = body.kaution }

        if let v = body.isWelcomeEmailSent { reg.isWelcomeEmailSent = v }
        if let v = body.isLoginDataSent { reg.isLoginDataSent = v }
        if let v = body.dateCreated { reg.dateCreated = v }

        // direct URL set (still supported)
        if let v = body.customerSignedContract { reg.customerSignedContract = v }
        if let v = body.adminSignedContract { reg.adminSignedContract = v }
        if let v = body.teamLogo { reg.teamLogo = v }

        // ---- File uploads (Firebase) ----
        let hasAnyFile =
            (body.teamLogoFile?.data.readableBytes ?? 0) > 0 ||
            (body.customerSignedContractFile?.data.readableBytes ?? 0) > 0 ||
            (body.adminSignedContractFile?.data.readableBytes ?? 0) > 0 ||
            (body.primaryIdentificationFile?.data.readableBytes ?? 0) > 0 ||
            (body.secondaryIdentificationFile?.data.readableBytes ?? 0) > 0

        if hasAnyFile {
            let firebaseManager = req.application.firebaseManager
            try await firebaseManager.authenticate().get()

            let regId = try reg.requireID()
            let basePath = "registrations/\(regId.uuidString)"

            // teamLogo
            if let f = body.teamLogoFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/teamLogo").get()
                reg.teamLogo = url
            }

            // customer contract (pdf)
            if let f = body.customerSignedContractFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/customerSignedContract").get()
                reg.customerSignedContract = url
            }

            // admin contract (pdf)
            if let f = body.adminSignedContractFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/adminSignedContract").get()
                reg.adminSignedContract = url
            }

            // primary identification -> primary.identification URL
            if let f = body.primaryIdentificationFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/primaryIdentification").get()
                if let primary = reg.primary {
                    reg.primary = primary.withIdentification(url)
                }
            }

            // secondary identification -> secondary.identification URL
            if let f = body.secondaryIdentificationFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/secondaryIdentification").get()
                if let secondary = reg.secondary {
                    reg.secondary = secondary.withIdentification(url)
                }
            }
        }

        try await reg.save(on: req.db)
        return reg
    }

    // POST /admin/registrations/register  (multipart/form-data)
    // draft creation + welcome email + optional file uploads
    func register(req: Request) async throws -> HTTPStatus {
        let registrationRequest = try req.content.decode(TeamRegistrationRequest.self)

        let newRegistration = TeamRegistration()
        newRegistration.primary = registrationRequest.primaryContact
        newRegistration.secondary = registrationRequest.secondaryContact
        newRegistration.teamName = registrationRequest.teamName
        newRegistration.verein = registrationRequest.verein
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.status = .draft
        newRegistration.paidAmount = 0.0
        newRegistration.bundesland = registrationRequest.bundesland
        newRegistration.initialPassword = registrationRequest.initialPassword ?? String.randomString(length: 8)
        newRegistration.customerSignedContract = nil
        newRegistration.adminSignedContract = nil
        newRegistration.teamLogo = nil
        newRegistration.isWelcomeEmailSent = true
        newRegistration.isLoginDataSent = false
        newRegistration.dateCreated = Date.viennaNow

        // Save first to get stable id for upload paths
        try await newRegistration.save(on: req.db)

        // Optional uploads
        let anyFile =
            (registrationRequest.teamLogoFile?.data.readableBytes ?? 0) > 0 ||
            (registrationRequest.customerSignedContractFile?.data.readableBytes ?? 0) > 0 ||
            (registrationRequest.adminSignedContractFile?.data.readableBytes ?? 0) > 0 ||
            (registrationRequest.primaryIdentificationFile?.data.readableBytes ?? 0) > 0 ||
            (registrationRequest.secondaryIdentificationFile?.data.readableBytes ?? 0) > 0

        if anyFile {
            let firebaseManager = req.application.firebaseManager
            try await firebaseManager.authenticate().get()

            let regId = try newRegistration.requireID()
            let basePath = "registrations/\(regId.uuidString)"

            if let f = registrationRequest.teamLogoFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/teamLogo").get()
                newRegistration.teamLogo = url
            }

            if let f = registrationRequest.customerSignedContractFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/customerSignedContract").get()
                newRegistration.customerSignedContract = url
            }

            if let f = registrationRequest.adminSignedContractFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/adminSignedContract").get()
                newRegistration.adminSignedContract = url
            }

            if let f = registrationRequest.primaryIdentificationFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/primaryIdentification").get()
                newRegistration.primary = newRegistration.primary?.withIdentification(url)
            }

            if let f = registrationRequest.secondaryIdentificationFile, f.data.readableBytes > 0 {
                let url = try await firebaseManager.uploadFile(file: f, to: "\(basePath)/secondaryIdentification").get()
                newRegistration.secondary = newRegistration.secondary?.withIdentification(url)
            }

            try await newRegistration.save(on: req.db)
        }

        sendWelcomeEmailInBackground(
            req: req,
            recipient: registrationRequest.primaryContact.email,
            registration: newRegistration
        )

        return .ok
    }

    // POST /admin/registrations/confirm/:id
    func confirm(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        reg.status = .approved

        let passwordForEmail = reg.initialPassword ?? String.randomString(length: 8)
        if reg.initialPassword == nil { reg.initialPassword = passwordForEmail }

        guard let leagueId = reg.assignedLeague else {
            throw Abort(.badRequest, reason: "assignedLeague is missing.")
        }

        let user = try await resolveUser(for: reg, on: req)
        if reg.user == nil, let uid = user.id { reg.user = uid }

        let league = try await requireLeagueByID(leagueId, db: req.db)

        try await reg.save(on: req.db)

        let team = Team(
            sid: String.randomNum(length: 5),
            userId: user.id,
            leagueId: leagueId,
            leagueCode: league.code,
            points: 0,
            coverimg: "",
            logo: reg.teamLogo ?? "",
            teamName: reg.teamName,
            foundationYear: Date.viennaNow.yearString,
            membershipSince: Date.viennaNow.yearString,
            averageAge: "0",
            coach: Trainer(name: "", email: "", image: ""),
            trikot: Trikot(home: "", away: ""),
            balance: reg.paidAmount ?? 0.0,
            usremail: reg.primary?.email,
            usrpass: reg.initialPassword,
            usrtel: reg.primary?.phone,
            kaution: reg.kaution
        )

        try await team.save(on: req.db)

        sendTeamLoginInBackground(
            req: req,
            recipient: user.email,
            email: user.email,
            password: passwordForEmail
        )

        return .ok
    }

    // POST /admin/registrations/reject/:id
    func reject(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        reg.status = .rejected
        try await reg.save(on: req.db)
        return .ok
    }

    // POST /admin/registrations/assign/:id/league/:leagueid
    func assignLeague(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        guard let leagueID = req.parameters.get("leagueid", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid leagueid.")
        }

        let league = try await requireLeagueByID(leagueID, db: req.db)

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

        reg.assignedLeague = leagueID
        reg.kaution = 300.00

        if let currentPaidAmount = reg.paidAmount {
            reg.paidAmount = currentPaidAmount - topayAmount
        } else {
            reg.paidAmount = -(topayAmount + (reg.kaution ?? 0))
        }

        try await reg.save(on: req.db)

        sendPaymentInstructionsInBackground(
            req: req,
            recipient: reg.primary?.email ?? "",
            registration: reg
        )

        return .ok
    }

    // POST /admin/registrations/updatePayment/:id
    func updatePaymentConfirmation(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        let paymentRequest = try req.content.decode(UpdatePaymentRequest.self)

        if let current = reg.paidAmount {
            reg.paidAmount = current + paymentRequest.paidAmount
        } else {
            reg.paidAmount = paymentRequest.paidAmount
        }

        try await reg.save(on: req.db)
        return .ok
    }

    // POST /admin/registrations/completeRegistration/:id
    func startTeamCustomization(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")

        let passwordForEmail = reg.initialPassword ?? String.randomString(length: 8)
        if reg.initialPassword == nil { reg.initialPassword = passwordForEmail }

        let user = try await resolveUser(for: reg, on: req)
        if reg.user == nil, let uid = user.id { reg.user = uid }

        let team = Team(
            sid: "",
            userId: try user.requireID(),
            leagueId: reg.assignedLeague,
            leagueCode: reg.assignedLeague?.uuidString,
            points: 0,
            coverimg: "",
            logo: "",
            teamName: reg.teamName,
            foundationYear: "",
            membershipSince: "",
            averageAge: "",
            coach: Trainer(name: "", email: "", image: ""),
            trikot: Trikot(home: "", away: ""),
            referCode: reg.refereerLink,
            usremail: reg.primary?.email,
            usrpass: reg.initialPassword,
            usrtel: reg.primary?.phone
        )

        try await reg.save(on: req.db)
        try await team.save(on: req.db)

        return .ok
    }
}

// MARK: - Helpers
private extension AdminController {

    func requireRegistration(req: Request, param: String) async throws -> TeamRegistration {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid registration ID.")
        }
        guard let reg = try await TeamRegistration.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Registration not found.")
        }
        return reg
    }

    func requireLeagueByID(_ id: UUID, db: Database) async throws -> League {
        guard let league = try await League.find(id, on: db) else {
            throw Abort(.notFound, reason: "League not found.")
        }
        return league
    }

    // Rule preserved:
    // - If registration.user exists -> use that user (do NOT create new).
    // - Else create a user from primary contact.
    func resolveUser(for registration: TeamRegistration, on req: Request) async throws -> User {
        if let attachedUserId = registration.user {
            guard let user = try await User.find(attachedUserId, on: req.db) else {
                throw Abort(.notFound, reason: "Attached user not found")
            }
            return user
        }

        let primaryEmail = (registration.primary?.email ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !primaryEmail.isEmpty else {
            throw Abort(.badRequest, reason: "Primary contact email is missing")
        }

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

        let user = try User.create(from: userSignup)
        try await user.save(on: req.db)
        return user
    }

    // Email helpers
    func sendWelcomeEmailInBackground(req: Request, recipient: String, registration: TeamRegistration?) {
        let emailController = EmailController()
        req.eventLoop.execute {
            do {
                try emailController
                    .sendWelcomeMail(req: req, recipient: recipient, registration: registration)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            req.logger.info("Welcome email sent to \(recipient)")
                        case .failure(let err):
                            req.logger.warning("Welcome email failed to \(recipient): \(err)")
                        }
                    }
            } catch {
                req.logger.warning("Failed to start welcome email to \(recipient): \(error)")
            }
        }
    }

    func sendTeamLoginInBackground(req: Request, recipient: String, email: String, password: String) {
        let emailController = EmailController()
        req.eventLoop.execute {
            do {
                try emailController
                    .sendTeamLogin(req: req, recipient: recipient, email: email, password: password)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            req.logger.info("Team login email sent to \(recipient)")
                        case .failure(let err):
                            req.logger.warning("Team login email failed to \(recipient): \(err)")
                        }
                    }
            } catch {
                req.logger.warning("Failed to start team login email to \(recipient): \(error)")
            }
        }
    }

    func sendPaymentInstructionsInBackground(req: Request, recipient: String, registration: TeamRegistration) {
        let emailController = EmailController()
        req.eventLoop.execute {
            do {
                try emailController
                    .sendPaymentMail(req: req, recipient: recipient, registration: registration)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            req.logger.info("Payment email sent to \(recipient)")
                        case .failure(let err):
                            req.logger.warning("Payment email failed to \(recipient): \(err)")
                        }
                    }
            } catch {
                req.logger.warning("Failed to start payment email to \(recipient): \(error)")
            }
        }
    }
}

