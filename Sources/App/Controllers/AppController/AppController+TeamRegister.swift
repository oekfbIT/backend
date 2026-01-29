//
//  TeamRegistration+EmailVerification.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 28.01.26.
//

import Foundation
import Vapor
import Fluent

struct TeamAppRegistrationRequest: Content {
    let firstName: String
    let lastName: String
    let email: String
    let tel: String?
    let password: String
}

struct TeamAppRegistrationResponse: Content {
    let userId: UUID
    let email: String
    let verified: Bool
}

struct TeamAppApplicationRequest: Content {
    // Form fields
    let teamName: String
    let verein: String?
    let bundesland: Bundesland

    // These come as JSON-strings from the app (LosslessStringConvertible works)
    let primary: ContactPerson
    let secondary: ContactPerson

    // Files
    let primaryIdentification: File
    let secondaryIdentification: File
    let signedContract: File
    let teamLogo: File
}

struct TeamAppApplicationResponse: Content {
    let registrationId: UUID
    let status: TeamRegistrationStatus
    let created: Date?
}

extension AppController {

    func setupTeamRegistrationRoutes(on root: RoutesBuilder) {
        let teamregistration = root.grouped("application")

        // ✅ create team-user + send verification email
        teamregistration.post("request", use: requestTeamRegistration)

        // ✅ verification route
        let user = teamregistration.grouped("user")
        let verify = user.grouped("verify")
        verify.get(":code", use: verifyEmailByCode)
        // => GET /app/application/user/verify/:code

        // ✅ NEW: apply -> create TeamRegistration + upload docs
        teamregistration.post("apply", use: applyTeamApplication)
        // => POST /app/application/apply

        // ✅ registrations by user id
        let registrations = teamregistration.grouped("registrations")
        registrations.get("user", ":userId", use: getTeamRegistrationsByUser)
        // => GET /app/application/registrations/user/:userId
    }

    // POST /app/application/apply
    func applyTeamApplication(req: Request) async throws -> TeamAppApplicationResponse {

        // ✅ must be logged in user
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        // ✅ decode multipart/form-data
        let input = try req.content.decode(TeamAppApplicationRequest.self)

        // Optional: require verified email before applying
        // guard user.verified == true else {
        //     throw Abort(.unauthorized, reason: "Bitte bestätigen Sie zuerst Ihre E-Mail-Adresse.")
        // }

        // Optional: prevent multiple active registrations
        if let _ = try await TeamRegistration.query(on: req.db)
            .filter(\.$user == userId)
            .filter(\.$status != .completed)
            .first()
        {
            throw Abort(.conflict, reason: "Es existiert bereits eine aktive Anmeldung für diesen Benutzer.")
        }

        // ✅ Firebase auth (if you already do this at app boot, you can remove)
        try await req.application.firebaseManager.authenticate().get()

        let basePath = "teamapplications/\(userId.uuidString)/\(UUID().uuidString)"

        // ✅ upload files to Firebase
        let primaryIdUrl = try await req.application.firebaseManager
            .uploadFile(file: input.primaryIdentification, to: "\(basePath)/primary_id")
            .get()

        let secondaryIdUrl = try await req.application.firebaseManager
            .uploadFile(file: input.secondaryIdentification, to: "\(basePath)/secondary_id")
            .get()

        let contractUrl = try await req.application.firebaseManager
            .uploadFile(file: input.signedContract, to: "\(basePath)/signed_contract")
            .get()

        let logoUrl = try await req.application.firebaseManager
            .uploadFile(file: input.teamLogo, to: "\(basePath)/team_logo")
            .get()

        // ✅ attach identification URLs into ContactPerson objects
        let primary = ContactPerson(
            first: input.primary.first,
            last: input.primary.last,
            phone: input.primary.phone,
            email: input.primary.email,
            identification: primaryIdUrl
        )

        let secondary = ContactPerson(
            first: input.secondary.first,
            last: input.secondary.last,
            phone: input.secondary.phone,
            email: input.secondary.email,
            identification: secondaryIdUrl
        )

        // ✅ create registration
        let registration = TeamRegistration(
            id: nil,
            primary: primary,
            secondary: secondary,
            verein: input.verein,
            teamName: input.teamName,
            status: .draft,
            bundesland: input.bundesland,
            initialPassword: String.randomString(length: 8), // required by your migration
            refereerLink: nil,
            assignedLeague: nil,
            customerSignedContract: contractUrl,
            adminSignedContract: nil,
            teamLogo: logoUrl,
            paidAmount: 0.0,
            user: userId,
            team: nil,
            isWelcomeEmailSent: true,
            isLoginDataSent: false,
            dateCreated: Date.viennaNow,
            kaution: nil
        )

        try await registration.save(on: req.db)
        let regId = try registration.requireID()

        // ✅ send welcome mail right away (same pattern as your old controller)
        let emailController = EmailController()
        let recipient = primary.email

        req.eventLoop.execute {
            do {
                try emailController
                    .sendWelcomeMail(req: req, recipient: recipient, registration: registration)
                    .whenComplete { result in
                        switch result {
                        case .success:
                            print("[applyTeamApplication] welcome email sent to \(recipient)")
                        case .failure(let error):
                            print("[applyTeamApplication] welcome email FAILED: \(error)")
                        }
                    }
            } catch {
                print("[applyTeamApplication] welcome email start FAILED: \(error)")
            }
        }

        return TeamAppApplicationResponse(
            registrationId: regId,
            status: registration.status,
            created: registration.dateCreated
        )
    }

    // GET /app/application/registrations/user/:userId
    func getTeamRegistrationsByUser(req: Request) async throws -> [TeamRegistration] {
        guard
            let userIdParam = req.parameters.get("userId"),
            let userId = UUID(uuidString: userIdParam)
        else {
            throw Abort(.badRequest, reason: "Invalid or missing userId.")
        }

        return try await TeamRegistration.query(on: req.db)
            .filter(\.$user == userId)
            .filter(\.$status != .completed)
            .sort(\.$dateCreated, .descending) // optional
            .all()
    }

    // POST /app/teamregistration/request
    func requestTeamRegistration(req: Request) async throws -> TeamAppRegistrationResponse {
        let input = try req.content.decode(TeamAppRegistrationRequest.self)

        // Prevent duplicate accounts by email (ANY user type)
        if let existing = try await User.query(on: req.db)
            .filter(\.$email == input.email)
            .first()
        {
            let typeLabel = existing.type.position
            throw Abort(
                .conflict,
                reason: "Ein Benutzer mit dieser E-Mail existiert bereits (\(typeLabel)). Bitte verwenden Sie eine andere E-Mail-Adresse."
            )
        }

        // Create user with verified=false
        let user = User(
            userID: UUID().uuidString,
            type: .team,
            firstName: input.firstName,
            lastName: input.lastName,
            verified: false,
            email: input.email,
            tel: input.tel,
            passwordHash: try Bcrypt.hash(input.password)
        )

        try await user.save(on: req.db)
        let userId = try user.requireID()

        // Create and store verification code
        let code = String.randomNum(length: 6)
        let verification = VerificationCode(
            code: code,
            userid: userId,
            email: input.email,
            status: .sent
        )
        try await verification.save(on: req.db)

        // Send verification LINK (backend GET route)
        let verificationUrl = "https://www.oekfb.eu/#/app/application/user/verify/\(code)"
        let emailController = EmailController()
        try await emailController
            .sendEmailVerificationLink(req: req, recipient: input.email, verificationUrl: verificationUrl)
            .get()

        return TeamAppRegistrationResponse(
            userId: userId,
            email: input.email,
            verified: false
        )
    }

    
    //
    
    
    // GET /app/user/verify/:code
    func verifyEmailByCode(req: Request) async throws -> HTTPStatus {
        guard let code = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "Missing verification code.")
        }

        // find ALL verifications that match this code (use latest one)
        let matches = try await VerificationCode.query(on: req.db)
            .filter(\.$code == code)
            .sort(\.$created, .descending)
            .all()

        guard let verification = matches.first else {
            throw Abort(.badRequest, reason: "Invalid or expired verification link.")
        }

        // Find the user from the verification
        let user: User? = await {
            if let uid = verification.userid {
                return try? await User.find(uid, on: req.db)
            }
            if let mail = verification.email {
                return try? await User.query(on: req.db).filter(\.$email == mail).first()
            }
            return nil
        }()

        guard let user else {
            throw Abort(.notFound, reason: "User not found for this verification.")
        }

        // already verified -> just return ok
        if user.verified == true {
            return .ok
        }

        // mark user + all matching verifications as verified
        user.verified = true
        try await user.save(on: req.db)

        for v in matches {
            v.status = .verified
            try await v.save(on: req.db)
        }

        return .ok
    }

    private func htmlResponse(_ html: String) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }
}
