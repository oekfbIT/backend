//
//  File.swift
//  
//
//  Created by Alon Yakoby on 29.05.24.
//

import Vapor
import Smtp
import NIO

let vertragLink = "https://firebasestorage.googleapis.com/v0/b/oekfbbucket.appspot.com/o/adminfiles%2FOEKFB%20Anmelde%20Vertrag.pdf.pdf?alt=media&token=23ab12e2-f360-48f5-b4f9-aa1cb3d64305"

final class EmailController {
    
    let baseConfig = BaseTemplate(logoUrl: "",
                                  title: "",
                                  description: "",
                                  buttonText: "",
                                  buttonUrl: "",
                                  assurance: "",
                                  disclaimer: "")
    
    let smtpConfig = SmtpServerConfiguration(
        hostname: "smtp.easyname.com",
        port: 587,  // Use port 587 for STARTTLS
        signInMethod: .credentials(username: "admin@oekfb.eu", password: "Oekfb$2024"),
        secure: .startTls,
        helloMethod: .ehlo  // Use EHLO instead of HELO
    )

    func sendTestEmail(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig
        
        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        let email = try Email(
            from: EmailAddress(address: "admin@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: "alon.yakoby@gmail.com", name: "Alon Yakoby")],
            subject: "Test Email",
            body: "This is a test email sent from Vapor application."
        )
        
        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                print("Email failed to send: \(error)")
                throw Abort(.internalServerError, reason: "Failed to send email")
            }
        }
    }
    
    func sendEmailWithData(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig
        
        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Prepare the email content
        let emailBody = """
        Thank you for your registration.

        Login: \(email)
        Password: \(password)
        """

        let email = try Email(
            from: EmailAddress(address: "admin@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "Registration Details",
            body: emailBody
        )

        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                print("Email failed to send: \(error)")
                throw Abort(.internalServerError, reason: "Failed to send email")
            }
        }
    }
    
    func sendWelcomeMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig
        guard let registrationID = registration?.id else {
            throw Abort(.notFound)

        }
        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        let emailBody = """
        <html>
        <body>
        <p>Sehr geehrter Mannschaftsleiter,</p>

        <p>Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund. Bitte senden Sie uns den Vertrag im Anhang ausgefüllt zurück.
        Wir benötigen noch folgende Unterlagen:</p>

        <ul>
          <li>Ausweiskopie beider Personen am Vertrag (<a href="\(vertragLink)" style="font-size: 16px; color: #007bff; text-decoration: none;">Vertrag Downloaden</a>)</li>
          <li>Logo des Teams</li>
          <li>Bilder der Trikots (Heim und Auswärts komplett inklusive Stutzen)</li>
          <li>Sie können diese Dokumente über diesen link Hochladen (<a href="https://oekfb.eu/team/upload/\(registrationID)" style="font-size: 16px; color: #007bff; text-decoration: none;">Upload Page</a>)</li>
        </ul>

        <p>Falls Sie Trikots benötigen und noch keine haben, können Sie sich über die Angebote für ÖKFB Mannschaften hier erkundigen: <a href="https://www.kaddur.at">www.kaddur.at</a></p>

        <p>Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "admin@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Willkommen",
            body: emailBody,
            isBodyHtml: true
        )

        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                print("Email failed to send: \(error)")
                throw Abort(.internalServerError, reason: "Failed to send email")
            }
        }
    }

    // UPDATE THIS MAIL TEMPLATE
    func sendPaymentMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig
        guard let registrationID = registration?.id else {
            throw Abort(.notFound)

        }
        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        let emailBody = """
        <html>
        <body>
        <p>Sehr geehrter Mannschaftsleiter,</p>
        <p></p>
        <p>Ihre Unterlagen haben gepasst und anbei ist die Zahlungsanforderung</p>

        <ul>
          <li>Ausweiskopie beider Personen am Vertrag (<a href="\(vertragLink)" style="font-size: 16px; color: #007bff; text-decoration: none;">Vertrag Downloaden</a>)</li>
          <li>Logo des Teams</li>
          <li>Bilder der Trikots (Heim und Auswärts komplett inklusive Stutzen)</li>
          <li>Sie können diese Dokumente über diesen link Hochladen (<a href="https://oekfb.eu/team/upload/\(registrationID)" style="font-size: 16px; color: #007bff; text-decoration: none;">Upload Page</a>)</li>
        </ul>

        <p>Falls Sie Trikots benötigen und noch keine haben, können Sie sich über die Angebote für ÖKFB Mannschaften hier erkundigen: <a href="https://www.kaddur.at">www.kaddur.at</a></p>

        <p>Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "admin@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Willkommen",
            body: emailBody,
            isBodyHtml: true
        )

        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                print("Email failed to send: \(error)")
                throw Abort(.internalServerError, reason: "Failed to send email")
            }
        }
    }
    
    func sendPaymentInstruction(req: Request, recipient: String, due: Double) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig

        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Prepare the email content in German
        let emailBody = """
        Sehr geehrter Mannschaftsleiter,

        Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund. Bitte senden Sie uns den Vertrag im Anhang ausgefüllt zurück.
        Wir benötigen noch folgende Unterlagen:

        · Ausweiskopie beider Personen am Vertrag
        · Logo des Teams
        · Bilder der Trikots (Heim und Auswärts komplett inklusive Stutzen)

        Falls Sie Trikots benötigen und noch keine haben, können Sie sich über die Angebote für ÖKFB Mannschaften hier erkundigen: www.kaddur.at

        Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.
        """

        let email = try Email(
            from: EmailAddress(address: "admin@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Willkommen",
            body: emailBody
        )

        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                print("Email failed to send: \(error)")
                throw Abort(.internalServerError, reason: "Failed to send email")
            }
        }
    }
}
