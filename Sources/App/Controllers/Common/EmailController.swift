//
//  File.swift
//  
//
//  Created by Alon Yakoby on 29.05.24.
//

import Vapor
import Smtp
import NIO

final class EmailController {
    private var smtpHost: String { Environment.get("SMTP_HOST") ?? "smtp.easyname.com" }
    private var smtpPort: Int { Int(Environment.get("SMTP_PORT") ?? "587") ?? 587 }
    private var smtpUser: String { Environment.get("SMTP_USERNAME") ?? "" }
    private var smtpPass: String { Environment.get("SMTP_PASSWORD") ?? "" }
    private var fromAddress: String { Environment.get("SMTP_FROM_ADDRESS") ?? "office@oekfb.eu" }
    private var fromName: String { Environment.get("SMTP_FROM_NAME") ?? "Admin" }
    
    private func senderEmail() -> EmailAddress {
        EmailAddress(address: fromAddress, name: fromName)
    }

    /// Every outgoing message is copied privately to the backend's sender mailbox.
    private func copyRecipients(recipient: String) -> [EmailAddress] {
        let address = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        // A mailbox already in To must not receive a second copy.
        guard !address.isEmpty,
              address.caseInsensitiveCompare(recipient.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame else {
            return []
        }
        return [EmailAddress(address: address)]
    }
    
    private func applySMTPConfig(_ req: Request) throws {
        try applySMTPConfig(req.application)
    }

    private func applySMTPConfig(_ application: Application) throws {
        guard !smtpUser.isEmpty, !smtpPass.isEmpty else {
            application.logger.error("SMTP credentials are not configured.")
            throw Abort(.internalServerError, reason: "Email service not configured")
        }
        
        application.smtp.configuration = SmtpServerConfiguration(
            hostname: smtpHost,
            port: smtpPort,
            signInMethod: .credentials(username: smtpUser, password: smtpPass),
            secure: .startTls,
            helloMethod: .ehlo
        )
    }

    func sendTeamTopUpConfirmation(application: Application, topUp: TeamTopUp) async throws {
        try applySMTPConfig(application)
        _ = try Self.teamTopUpBody(topUp) // Validate credited payment before preparing any message.
        let date = DateFormatter()
        date.locale = Locale(identifier: "de_AT")
        date.timeZone = TimeZone(identifier: "Europe/Vienna")
        date.dateFormat = "dd.MM.yyyy HH:mm zzz"
        let money = NumberFormatter()
        money.locale = Locale(identifier: "de_AT"); money.numberStyle = .currency; money.currencyCode = "EUR"
        func amount(_ value: Double) -> String { money.string(from: NSNumber(value: value)) ?? String(format: "%.2f EUR", value) }
        let rendered = try await EmailTemplateService.render(key: "teamTopUp", values: [
            "invoiceNumber": topUp.invoiceNumber, "teamName": topUp.teamName,
            "amount": amount(Double(topUp.amountMinor) / 100),
            "fee": amount(Double(topUp.effectiveCreditPolicy == .stripeNet ? (topUp.feeMinor ?? 0) : 0) / 100),
            "credit": amount(Double(try topUp.creditAmountMinor) / 100),
            "paidAt": date.string(from: topUp.paidAt!), "transaction": topUp.paymentIntentID!,
            "balanceBefore": amount(topUp.balanceBefore!), "balanceAfter": amount(topUp.balanceAfter!),
            "sandbox": topUp.livemode ? "" : "SANDBOX: Dies war eine Testzahlung."
        ], on: application.db)
        let email = try Email(from: senderEmail(), to: [EmailAddress(address: topUp.recipient)],
                              bcc: copyRecipients(recipient: topUp.recipient),
                              subject: rendered.subject, body: rendered.html, isBodyHtml: true)
        try await application.smtp.send(email)
    }

    static func teamTopUpBody(_ topUp: TeamTopUp) throws -> String {
        guard topUp.creditedAt != nil, let paidAt = topUp.paidAt,
              let before = topUp.balanceBefore, let after = topUp.balanceAfter,
              let transaction = topUp.paymentIntentID else {
            throw Abort(.conflict, reason: "Cannot email an uncredited top-up.")
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "de_AT")
        date.timeZone = TimeZone(identifier: "Europe/Vienna")
        date.dateFormat = "dd.MM.yyyy HH:mm zzz"
        let money = NumberFormatter()
        money.locale = Locale(identifier: "de_AT"); money.numberStyle = .currency; money.currencyCode = "EUR"
        func amount(_ value: Double) -> String { money.string(from: NSNumber(value: value)) ?? String(format: "%.2f EUR", value) }
        return """
        Guten Tag,

        die Einzahlung für \(topUp.teamName) wurde erfolgreich Ihrem Mannschaftskonto gutgeschrieben.

        Eingezahlt: \(amount(Double(topUp.amountMinor) / 100))
        Abgezogene Stripe-Gebühren: \(amount(Double(topUp.effectiveCreditPolicy == .stripeNet ? (topUp.feeMinor ?? 0) : 0) / 100))
        Gutgeschrieben: \(amount(Double(try topUp.creditAmountMinor) / 100))
        Bezahlt am: \(date.string(from: paidAt))
        Belegnummer: \(topUp.invoiceNumber)
        Transaktions-ID (Stripe): \(transaction)
        Guthaben vorher: \(amount(before))
        Guthaben nachher: \(amount(after))

        Den bezahlten Einzahlungsbeleg finden Sie in Ihrer Finanzhistorie.
        \(topUp.livemode ? "" : "SANDBOX: Dies war eine Testzahlung.")
        Sportliche Grüße
        Ihr ÖKFB Team
        """
    }

    func sendTeamAccountPassword(req: Request, recipient: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        return sendTemplate(req: req, recipient: recipient, key: "sendTeamAccountPassword", values: ["email": String(describing: recipient), "password": String(describing: password)])

    }

    func sendTestEmail(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        
        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: "alon.yakoby@gmail.com", key: "sendTestEmail", values: [:])

    }
    
    func sendEmailWithData(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        
        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendEmailWithData", values: ["email": String(describing: email), "password": String(describing: password)])

    }

    func sendPlayerEligibilityDecision(
        req: Request,
        recipient: String,
        player: Player,
        approved: Bool,
        rejectionReason: String?
    ) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)

        return sendTemplate(req: req, recipient: recipient, key: approved ? "playerApproved" : "playerRejected", values: [
            "playerName": player.name, "playerSid": player.sid,
            "rejectionReason": rejectionReason ?? "Die Voraussetzungen für die Freigabe wurden nicht erfüllt."
        ])

    }
    
    func sendRegistrationNotice(req: Request, recipient: String, event: String, values: [String: String]) throws -> EventLoopFuture<HTTPStatus> {
        if let transport = req.application.storage[RegistrationMailTransportKey.self] { return transport(req, "sendRegistrationNotice") }
        try applySMTPConfig(req)
        return sendTemplate(req: req, recipient: recipient, key: "registration." + event, values: values)
    }

    private func sendTemplate(req: Request, recipient: String, key: String, values: [String: String]) -> EventLoopFuture<HTTPStatus> {
        req.eventLoop.makeFutureWithTask {
            let rendered = try await EmailTemplateService.render(key: key, values: values, on: req.db)
            let email = try Email(from: self.senderEmail(), to: [EmailAddress(address: recipient)],
                                  bcc: self.copyRecipients(recipient: recipient),
                                  subject: rendered.subject, body: rendered.html, isBodyHtml: true)
            let result = try await req.smtp.send(email).get()
            switch result {
            case .success: return .ok
            case .failure: throw Abort(.badGateway, reason: "E-Mail konnte nicht gesendet werden.")
            }
        }
    }

    func sendWelcomeMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        guard let registration else { throw Abort(.notFound, reason: "Team registration not found") }
        return req.eventLoop.makeFutureWithTask {
            let values = try await RegistrationFlow.prepareDocumentInvitation(registration, req: req)
            if let transport = req.application.storage[RegistrationMailTransportKey.self] {
                return try await transport(req, "sendWelcomeMail").get()
            }
            try self.applySMTPConfig(req)
            return try await self.sendTemplate(req: req, recipient: recipient, key: "sendWelcomeMail", values: values).get()
        }
    }

    func sendPaymentMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        if let transport = req.application.storage[RegistrationMailTransportKey.self] { return transport(req, "sendPaymentMail") }
        try applySMTPConfig(req)
        
        // Ensure registration and registration ID exist
        guard let registration = registration, registration.id != nil else {
            throw Abort(.notFound, reason: "Team registration not found")
        }

        // Calculate the amount
        let amount: Double = max(0, -(registration.paidAmount ?? 0))


        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendPaymentMail", values: ["amount": String(format: "%.2f", amount), "deposit": String(describing: String(format: "%.2f", registration.kaution ?? 0)), "teamName": String(describing: registration.teamName.uppercased())])

    }

    func sendPaymentInstruction(req: Request, recipient: String, due: Double) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)

        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendPaymentInstruction", values: [:])

    }

    func sendRefLogin(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)

        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendRefLogin", values: ["email": String(describing: email), "password": String(describing: password)])

    }

    func sendTeamLogin(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        if let transport = req.application.storage[RegistrationMailTransportKey.self] { return transport(req, "sendTeamLogin") }
        try applySMTPConfig(req)

        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendTeamLogin", values: ["email": String(describing: email), "password": String(describing: password)])

    }

    func sendUpdatePlayerData(req: Request, recipient: String, player: Player) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)

        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendUpdatePlayerData", values: ["playerName": String(describing: player.name), "playerSid": String(describing: player.sid)])

    }

    func sendTransferRequest(req: Request, recipient: String, transfer: Transfer) throws -> EventLoopFuture<HTTPStatus> {
        let transferID = try transfer.requireID()
        let actionToken = try EmailActionLink.token(kind: "transfer", id: transferID)
        try applySMTPConfig(req)

        req.logger.debug("SMTP configuration applied")

        return sendTemplate(req: req, recipient: recipient, key: "sendTransferRequest", values: ["playerName": String(describing: transfer.playerName), "teamName": String(describing: transfer.teamName), "actionUrl": "https://oekfb.eu/#/transfer/\(transferID)?token=\(actionToken)"])

    }

}

extension EmailController {
    func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "unbekanntes Datum" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }

    func sendCancellationNotification(req: Request, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        
        let matchDateString = formatDate(match.details.date)

        return sendTemplate(req: req, recipient: recipient, key: "sendCancellationNotification", values: ["gameday": String(describing: match.details.gameday), "matchDate": String(describing: matchDateString)])

    }

    func sendPostPone(req: Request, postpone: PostponeRequest, cancellerName: String, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        let postponeID = try postpone.requireID()
        let actionToken = try EmailActionLink.token(kind: "postpone", id: postponeID)
        try applySMTPConfig(req)
        
        let matchDateString = formatDate(match.details.date)

        return sendTemplate(req: req, recipient: recipient, key: "sendPostPone", values: ["teamName": String(describing: cancellerName), "gameday": String(describing: match.details.gameday), "matchDate": String(describing: matchDateString), "actionUrl": "https://www.oekfb.eu/#/postpone/\(postponeID)?token=\(actionToken)"])

    }

    func approve(req: Request, approverName: String, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        
        let matchDateString = formatDate(match.details.date)

        return sendTemplate(req: req, recipient: recipient, key: "approve", values: ["teamName": String(describing: approverName), "gameday": String(describing: match.details.gameday), "matchDate": String(describing: matchDateString)])

    }

    func deny(req: Request, denierName: String, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        
        let matchDateString = formatDate(match.details.date)

        return sendTemplate(req: req, recipient: recipient, key: "deny", values: ["teamName": String(describing: denierName), "gameday": String(describing: match.details.gameday), "matchDate": String(describing: matchDateString)])

    }

    func informRefereeCancellation(req: Request, email: String, name: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        try applySMTPConfig(req)
        
        let matchDateString = formatDate(match.details.date)

        return sendTemplate(req: req, recipient: email, key: "informRefereeCancellation", values: ["homeTeam": String(describing: match.homeBlanket?.name ?? "Heimteam"), "awayTeam": String(describing: match.awayBlanket?.name ?? "Auswärtsteam"), "gameday": String(describing: match.details.gameday), "matchDate": String(describing: matchDateString)])

    }
}

// MARK: - EmailController: switch from "enter code" to "click link"

extension EmailController {

    func sendEmailVerificationLink(
        req: Request,
        recipient: String,
        verificationUrl: String
    ) throws -> EventLoopFuture<HTTPStatus> {
        if let transport = req.application.storage[RegistrationMailTransportKey.self] { return transport(req, "sendEmailVerificationLink") }

        try applySMTPConfig(req)

        req.logger.debug("SMTP configuration applied")
        req.logger.info("Sending verification link to: \(recipient)")
        req.logger.debug("Verification URL generated")


        return sendTemplate(req: req, recipient: recipient, key: "sendEmailVerificationLink", values: ["verificationUrl": String(describing: verificationUrl)])

    }
}
