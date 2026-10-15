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

// Shared registration prices are provided by FeeService.

// MARK: - Admin Registration Routes
extension AdminController {

    func setupRegistrationRoutes(on root: RoutesBuilder) {
        let regs = root.grouped("registrations")
        let readable = regs.grouped(PermissionMiddleware(.ordersRead))
        let manageable = regs.grouped(PermissionMiddleware(.ordersManage))

        // CRUD-ish
        readable.get(use: getAllRegistrations)
        readable.get(":id", use: getRegistrationByID)

        // multipart patch (optional files)
        manageable.patch(":id", use: patchRegistration)

        // Actions
        manageable.post("resendNotification", ":id", ":event", use: resendRegistrationNotification)
        manageable.post("requestDocuments", ":id", use: requestRegistrationDocuments)
        manageable.post("resendPayment", ":id", use: resendRegistrationPayment)
        manageable.post("resendWelcome", ":id", use: resendRegistrationWelcome)
        manageable.post("register", use: register)
        manageable.post("confirm", ":id", use: confirm)
        manageable.post("assign", ":id", "league", ":leagueid", use: assignLeague)
        manageable.post("reject", ":id", use: reject)
        manageable.post("updatePayment", ":id", use: updatePaymentConfirmation)
        manageable.post("completeRegistration", ":id", use: startTeamCustomization)
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
        let paymentId: UUID?
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
        try RegistrationFlow.requireEditable(reg)
        let body = try req.content.decode(PatchTeamRegistrationRequest.self)
        try [body.customerSignedContractFile, body.adminSignedContractFile, body.teamLogoFile, body.primaryIdentificationFile, body.secondaryIdentificationFile].compactMap { $0 }.forEach(RegistrationFlow.validateFile)

        // non-file fields
        if let v = body.primary { reg.primary = v }
        if let v = body.secondary { reg.secondary = v }
        if let v = body.verein { reg.verein = v }

        if let v = body.teamName {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "teamName cannot be empty.") }
            reg.teamName = t
        }

        if let v = body.status, v != reg.status {
            throw Abort(.badRequest, reason: "Bitte die Registrierungsaktionen für Statusänderungen verwenden.")
        }
        if let v = body.bundesland { reg.bundesland = v }

        if let v = body.initialPassword { reg.initialPassword = v }
        if let v = body.refereerLink { reg.refereerLink = v }
        if let v = body.assignedLeague { reg.assignedLeague = v }

        if let v = body.user { reg.user = v }
        if let v = body.team { reg.team = v }

        if body.paidAmount != nil { reg.paidAmount = body.paidAmount }
        if body.kaution != nil { reg.kaution = body.kaution }

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
        try RegistrationFlow.validateContact(registrationRequest.primaryContact)
        guard !registrationRequest.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Abort(.badRequest) }
        try [registrationRequest.customerSignedContractFile, registrationRequest.adminSignedContractFile, registrationRequest.teamLogoFile, registrationRequest.primaryIdentificationFile, registrationRequest.secondaryIdentificationFile].compactMap { $0 }.forEach(RegistrationFlow.validateFile)

        let newRegistration = TeamRegistration()
        newRegistration.primary = registrationRequest.primaryContact
        newRegistration.secondary = registrationRequest.secondaryContact
        newRegistration.teamName = registrationRequest.teamName
        newRegistration.verein = registrationRequest.verein
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.status = .draft
        newRegistration.paidAmount = 0.0
        newRegistration.bundesland = registrationRequest.bundesland
        newRegistration.initialPassword = String.randomString(length: 20)
        newRegistration.customerSignedContract = nil
        newRegistration.adminSignedContract = nil
        newRegistration.teamLogo = nil
        newRegistration.isWelcomeEmailSent = false
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

        _ = try? await RegistrationFlow.sendWelcome(req: req, registration: newRegistration).get()

        return .ok
    }

    // POST /admin/registrations/confirm/:id
    func confirm(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        if reg.team != nil {
            try await sendRegistrationApproval(reg, req: req)
            return .ok
        }
        // Repair registrations approved by the legacy flow, which omitted the team link.
        if [.approved, .teamCustomization].contains(reg.status), let owner = reg.user {
            let existing = try await Team.query(on: req.db).filter(\.$user.$id == owner).filter(\.$teamName == reg.teamName).all()
            guard existing.count <= 1 else {
                throw Abort(.conflict, reason: "Mehrere Mannschaften passen zu dieser Anmeldung. Bitte die Verknüpfung manuell prüfen.")
            }
            if let team = existing.first {
                reg.team = try team.requireID()
                reg.status = .approved
                try await reg.save(on: req.db)
                try await sendRegistrationApproval(reg, req: req)
                return .ok
            }
            // A previous attempt may have saved approval before failing to create the team.
            reg.status = .paid
        }
        try RegistrationFlow.requireEditable(reg)
        try RegistrationFlow.validateContact(reg.primary)
        try RegistrationFlow.validateContact(reg.secondary)
        guard RegistrationFlow.documentsComplete(reg), let balance = reg.paidAmount, balance.isFinite, balance >= 0,
              let leagueId = reg.assignedLeague else {
            throw Abort(.badRequest, reason: "Vertrag, beide Ausweise, Liga und vollständige Zahlung sind erforderlich.")
        }
        let league = try await requireLeagueByID(leagueId, db: req.db)
        let user = try await resolveUser(for: reg, on: req)
        reg.user = try user.requireID()
        // Stable identity makes retries safe even after a crash between the two saves.
        let teamID = try reg.requireID()
        if try await Team.find(teamID, on: req.db) == nil {
            let team = Team(id: teamID,
                sid: String.randomNum(length: 5), userId: user.id,
                leagueId: leagueId, leagueCode: league.code, points: 0, coverimg: "",
                logo: reg.teamLogo ?? "", teamName: reg.teamName,
                foundationYear: Date.viennaNow.yearString, membershipSince: Date.viennaNow.yearString,
                averageAge: "0", coach: Trainer(name: "", email: "", image: ""),
                trikot: Trikot(home: "", away: ""), balance: balance,
                usremail: user.email, usrpass: nil, usrtel: reg.primary?.phone, kaution: reg.kaution)
            do { try await team.create(on: req.db) }
            catch { guard try await Team.find(teamID, on: req.db) != nil else { throw error } }
        }
        reg.team = teamID
        reg.status = .approved
        try await reg.save(on: req.db)
        try await sendRegistrationApproval(reg, req: req)
        return .ok
    }

    private func sendRegistrationApproval(_ reg: TeamRegistration, req: Request) async throws {
        guard reg.isLoginDataSent != true else { return }
        guard let userID = reg.user, let user = try await User.find(userID, on: req.db) else { throw Abort(.notFound) }
        // Only registrations that created an account may send their generated password.
        if userID == reg.id, let password = reg.initialPassword {
            _ = try await EmailController().sendTeamLogin(req: req, recipient: user.email, email: user.email, password: password).get()
        } else {
            try await RegistrationFlow.notify(reg, event: "approved", req: req, recipient: user.email)
        }
        reg.isLoginDataSent = true
        try await reg.save(on: req.db)
    }

    // POST /admin/registrations/reject/:id
    func reject(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        guard reg.team == nil else { throw Abort(.conflict, reason: "Die Mannschaft wurde bereits angelegt.") }
        reg.status = .rejected
        try await reg.save(on: req.db)
        try await RegistrationFlow.notify(reg, event: "rejected", req: req)
        return .ok
    }

    // POST /admin/registrations/assign/:id/league/:leagueid
    func assignLeague(req: Request) async throws -> HTTPStatus {
        let fees = try await FeeService.forRequest(req)
        let leagueFixAmountPerGame = fees.fee(.registrationPerGame).euros
        let reg = try await requireRegistration(req: req, param: "id")
        guard let leagueID = req.parameters.get("leagueid", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid leagueid.")
        }

        try RegistrationFlow.requireEditable(reg)
        guard RegistrationFlow.documentsComplete(reg) else {
            throw Abort(.conflict, reason: "Bitte zuerst den unterschriebenen Vertrag und beide Ausweise vollständig einreichen lassen.")
        }
        try RegistrationFlow.validateContact(reg.primary)
        try RegistrationFlow.validateContact(reg.secondary)
        guard reg.assignedLeague == nil else {
            throw Abort(.conflict, reason: "Die Liga wurde bereits zugewiesen. Verwenden Sie Zahlungsinformation erneut senden.")
        }
        let league = try await requireLeagueByID(leagueID, db: req.db)

        let teamCount = max(league.teamcount ?? 0, 1)
        let topayAmount: Double
        switch teamCount {
        case 0...6:
            topayAmount = Double((teamCount - 1) * 2) * leagueFixAmountPerGame
        case 7...9:
            topayAmount = Double(teamCount - 1) * 1.5 * leagueFixAmountPerGame
        case 10...:
            topayAmount = Double(teamCount - 1) * leagueFixAmountPerGame
        default:
            topayAmount = 0.0
        }

        reg.assignedLeague = leagueID
        reg.kaution = fees.fee(.registrationDeposit).euros
        reg.appliedFees = [fees.fee(.registrationDeposit), fees.fee(.registrationPerGame)]

        reg.paidAmount = -(topayAmount + (reg.kaution ?? 0))
        try await reg.save(on: req.db)
        do {
            _ = try await EmailController().sendPaymentMail(req: req, recipient: reg.primary?.email ?? "", registration: reg).get()
            var deliveries = reg.emailDeliveries ?? [:]; deliveries["paymentRequested"] = "sent"; reg.emailDeliveries = deliveries
            try await reg.save(on: req.db)
        } catch {
            var deliveries = reg.emailDeliveries ?? [:]; deliveries["paymentRequested"] = "failed"; reg.emailDeliveries = deliveries
            try await reg.save(on: req.db)
            throw error
        }

        return .ok
    }

    // POST /admin/registrations/updatePayment/:id
    func updatePaymentConfirmation(req: Request) async throws -> HTTPStatus {
        let reg = try await requireRegistration(req: req, param: "id")
        try RegistrationFlow.requireEditable(reg)
        let paymentRequest = try req.content.decode(UpdatePaymentRequest.self)
        guard reg.assignedLeague != nil, paymentRequest.paidAmount.isFinite, paymentRequest.paidAmount != 0 else {
            throw Abort(.badRequest, reason: "Liga und gültiger Zahlungsbetrag erforderlich.")
        }

        let updated = try await RegistrationFlow.recordPayment(reg, amount: paymentRequest.paidAmount,
            paymentID: paymentRequest.paymentId ?? UUID(), req: req)
        try? await RegistrationFlow.notify(updated, event: "paymentReceived", req: req)
        return .ok
    }

    // POST /admin/registrations/completeRegistration/:id
    func startTeamCustomization(req: Request) async throws -> HTTPStatus {
        // Compatibility endpoint: use the same validated, idempotent approval.
        try await confirm(req: req)
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

        let accountID = try registration.requireID()
        if let existing = try await User.find(accountID, on: req.db) { return existing }
        if let existing = try await User.query(on: req.db).filter(\.$email == primaryEmail.lowercased()).first() {
            guard existing.type == .team else {
                throw Abort(.conflict, reason: "Diese E-Mail gehört zu einem anderen Kontotyp. Bitte die Zuordnung prüfen.")
            }
            // Admin approval links the existing account, without changing its credentials.
            return existing
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
        user.id = accountID
        do { try await user.create(on: req.db) }
        catch { guard let existing = try await User.find(accountID, on: req.db) else { throw error }; return existing }
        return user
    }

}

extension AdminController {
    func resendRegistrationWelcome(req: Request) async throws -> HTTPStatus {
        let registration = try await requireRegistration(req: req, param: "id")
        return try await RegistrationFlow.sendWelcome(req: req, registration: registration).get()
    }

    func requestRegistrationDocuments(req: Request) async throws -> HTTPStatus {
        let registration = try await requireRegistration(req: req, param: "id")
        let values = try await RegistrationFlow.prepareDocumentInvitation(registration, req: req)
        try await RegistrationFlow.notify(registration, event: "documentsRequested", req: req, values: values)
        return .ok
    }
}

extension AdminController {
    func resendRegistrationPayment(req: Request) async throws -> HTTPStatus {
        let registration = try await requireRegistration(req: req, param: "id")
        try RegistrationFlow.requireEditable(registration)
        guard registration.assignedLeague != nil else { throw Abort(.badRequest) }
        let result = try await EmailController().sendPaymentMail(req: req, recipient: registration.primary?.email ?? "", registration: registration).get()
        var deliveries = registration.emailDeliveries ?? [:]
        deliveries["paymentRequested"] = "sent"
        registration.emailDeliveries = deliveries
        try await registration.save(on: req.db)
        return result
    }
}

extension AdminController {
    func resendRegistrationNotification(req: Request) async throws -> HTTPStatus {
        let registration = try await requireRegistration(req: req, param: "id")
        let event = try req.parameters.require("event")
        switch event {
        case "documentsRequested": return try await requestRegistrationDocuments(req: req)
        case "paymentRequested": return try await resendRegistrationPayment(req: req)
        case "rejected":
            guard registration.status == .rejected else { throw Abort(.conflict) }
            return try await reject(req: req)
        case "approved":
            guard registration.team != nil else { throw Abort(.conflict) }
            try await sendRegistrationApproval(registration, req: req)
        case "documentsReceived":
            guard RegistrationFlow.documentsComplete(registration) else { throw Abort(.conflict) }
            try await RegistrationFlow.notify(registration, event: event, req: req)
        case "paymentReceived":
            guard registration.emailDeliveries?[event] != nil else { throw Abort(.conflict) }
            try await RegistrationFlow.notify(registration, event: event, req: req)
        case "adminRequestReceived", "adminDocumentsReceived":
            try await RegistrationFlow.notify(registration, event: event, req: req,
                recipient: Environment.get("REGISTRATION_ADMIN_EMAIL") ?? "office@oekfb.eu")
        default: throw Abort(.badRequest, reason: "Unbekannte Benachrichtigung.")
        }
        return .ok
    }
}
