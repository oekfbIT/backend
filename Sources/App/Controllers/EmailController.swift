import Vapor
import Smtp
import NIO

final class EmailController {

    let smtpConfig = SmtpServerConfiguration(
        hostname: "smtp.easyname.com",
        port: 587,  // Use port 587 for STARTTLS
        signInMethod: .credentials(username: "office@oekfb.eu", password: "oekfb$2024"),
        secure: .startTls,
        helloMethod: .ehlo  // Use EHLO instead of HELO
    )

    // A helper function to format date
    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "unbekanntes Datum" }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: date)
    }

    // Example of returning full email view
    func sendTestEmail(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        let emailBody = """
        <html>
        <body>
        <h2>Test Email</h2>
        <p>This is a test email sent from Vapor application.</p>
        </body>
        </html>
        """
        
        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: "office@oekfb.eu", name: "Admin")],
            subject: "Test Email",
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
    
    // Send email with registration details
    func sendEmailWithData(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        let emailBody = """
        <html>
        <body>
        <h2>Registration Details</h2>
        <p>Thank you for your registration.</p>
        <p><strong>Login:</strong> \(email)</p>
        <p><strong>Password:</strong> \(password)</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "Registration Details",
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

    func sendWelcomeMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        guard let registrationID = registration?.id else {
            throw Abort(.notFound)
        }
        
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
        <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
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
    
    // Return the full HTML body (completion-style return)
    func sendPaymentMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        guard let registration = registration, let registrationID = registration.id else {
            throw Abort(.notFound, reason: "Team registration not found")
        }

        let amount: Double = abs(Double(String(format: "%.2f", registration.paidAmount ?? 0.0)) ?? 0.0)

        var positivAmount: Double {
            return amount
        }

        let year = Calendar.current.component(.year, from: Date()) + 3

        let emailBody = """
        <html>
        <head>
            <style>
                body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; }
                p { margin-bottom: 10px; }
                ul { padding-left: 20px; }
                li { margin-bottom: 8px; }
                a { font-size: 16px; color: #007bff; text-decoration: none; }
            </style>
        </head>
        <body>
            <p>Sehr geehrter Mannschaftsleiter,</p>
            
            <p>Wir haben ihre korrekten Unterlagen erhalten. Anbei ist die Zahlungsaufforderung:</p>
            
            <ul>
                <li>Teilbetrag der Saison: € \(amount)</li>
                <li>Kaution: € 300.00 (Diese Kaution wird ihnen zur Saison \(year) auf ihr Guthaben dazugerechnet.)</li>
            </ul>
            
            <p>Bitte überweisen Sie die Summe von <strong>€ \(positivAmount)</strong> und verwenden Sie als Zahlungsreferenz bitte <strong>\(registration.teamName.uppercased())</strong>.</p>
            
            <p>Kontodaten:</p>
            <p>Österreichischer Kleinfeld Fußball Bund<br>
            AT26 2011 1829 7052 4200<br>
            GIBAATWWXXX</p>
                                    
            <p>Mit freundlichen Grüßen,<br>
            Österreichischer Kleinfeld Fußball Bund</p>
            <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Zahlungsanforderung",
            body: emailBody,
            isBodyHtml: true
        )

        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                print("Email failed to send: \(error.localizedDescription)")
                throw Abort(.internalServerError, reason: "Failed to send email: \(error.localizedDescription)")
            }
        }
    }
}
