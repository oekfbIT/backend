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

extension AppController {

    func setupTeamRegistrationRoutes(on root: RoutesBuilder) {
        let teamregistration = root.grouped("application")
        teamregistration.post("request", use: requestTeamRegistration)

        // formatted verification routes
        let user = teamregistration.grouped("user")
        let verify = user.grouped("verify")
        verify.get(":code", use: verifyEmailByCode)
        // => GET /app/application/user/verify/:code
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
        let verificationUrl = "https://www.oekfb.eu/app/user/verify/\(code)"
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

    // GET /app/user/verify/:code
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
