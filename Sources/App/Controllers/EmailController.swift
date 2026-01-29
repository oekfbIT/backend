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
        port: 587,
        signInMethod: .credentials(username: "office@oekfb.eu", password: "oekfb$2024"),
        secure: .startTls,
        helloMethod: .ehlo
    )

    func sendTestEmail(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig
        
        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
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
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
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

        <p>Herzlich Willkommen beim Österreichischen Kleinfeld Fußball Bund.</p>

        <p>
          Bitte laden Sie den Vertrag und die erforderlichen Unterlagen über die App hoch.
          Sollte etwas fehlen oder nicht in Ordnung sein, können Sie die Dokumente jederzeit in der App erneut hochladen oder Ihre Angaben bearbeiten.
          Je nach Status Ihrer Anmeldung werden bestimmte Bearbeitungsoptionen automatisch gesperrt.
          Alternativ können Sie uns die Unterlagen auch per E-Mail an <strong>office@oekfb.eu</strong> senden.
        </p>

        <ul>
          <li>Ausweiskopie beider Personen am Vertrag (<a href="\(vertragLink)" style="font-size: 16px; color: #007bff; text-decoration: none;">Vertrag downloaden</a>)</li>
          <li>Logo des Teams</li>
          <li>Bilder der Trikots (Heim und Auswärts komplett inklusive Stutzen)</li>
          <li>Upload-Link: <a href="https://oekfb.eu/#/team/upload/\(registrationID)" style="font-size: 16px; color: #007bff; text-decoration: none;">Upload Page</a></li>
        </ul>

        <p>
          Falls Sie Trikots benötigen und noch keine haben, können Sie sich über die Angebote für ÖKFB Mannschaften hier erkundigen:
          <a href="https://erima.shop/oekfb">https://erima.shop/oekfb</a>
        </p>

        <p>Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.</p>
        <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns zu kontaktieren.</p>
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

    func sendPaymentMail(req: Request, recipient: String, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig
        
        // Ensure registration and registration ID exist
        guard let registration = registration, let registrationID = registration.id else {
            throw Abort(.notFound, reason: "Team registration not found")
        }

        // Calculate the amount
        let amount: Double = abs(Double(String(format: "%.2f", registration.paidAmount ?? 0.0)) ?? 0.0)

        // Total amount to be paid including deposit
        var positivAmount: Double {
            return amount
        }

        // Calculate the year for the deposit return
        let year = Calendar.current.component(.year, from: Date.viennaNow) + 3

        // Debugging: Print the SMTP configuration
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Email content
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

        // Creating the email object
        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Zahlungsanforderung",
            body: emailBody,
            isBodyHtml: true
        )

        // Sending the email
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

        Falls Sie Trikots benötigen und noch keine haben, können Sie sich über die Angebote für ÖKFB Mannschaften hier erkundigen: https://erima.shop/oekfb

        Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.
        
        Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
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
    
    
    func sendRefLogin(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig

        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Prepare the email content in German
        let emailBody = """
        Sehr geehrter Schiedsrichter,

        Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund.
        
        Anbei sind ihre Login Daten:
        
        Email: \(email)
        Passwort: \(password)
        
        Sie können sich einlogen unter https://ref.oekfb.eu.
        
        Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
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

    func sendTeamLogin(req: Request, recipient: String, email: String, password: String) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig

        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Prepare the email content in German
        let emailBody = """
        Sehr geehrter Mannschaftsleiter,

        Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund.
        
        Anbei sind ihre Login Daten:
        
        Email: \(email)
        Passwort: \(password)
        
        Sie können sich einlogen unter https://team.oekfb.eu.
        
        Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Mannschaft Login Daten",
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

    func sendUpdatePlayerData(req: Request, recipient: String, player: Player) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig

        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Prepare the email content in German with HTML formatting and styling
        let emailBody = """
        <!DOCTYPE html>
        <html lang="de">
        <head>
            <meta charset="UTF-8">
            <title>Spielerdaten Update</title>
            <style>
                body {
                    font-family: Arial, sans-serif;
                    line-height: 1.6;
                    color: #333;
                    margin: 0;
                    padding: 20px;
                    background-color: #f8f9fa;
                }
                p {
                    margin: 0 0 15px 0;
                }
                ul {
                    margin: 0 0 15px 20px;
                    padding: 0;
                    list-style-type: disc;
                }
                li {
                    margin-bottom: 10px;
                }
                a {
                    color: #007bff;
                    text-decoration: none;
                }
                a:hover {
                    text-decoration: underline;
                }
                .signature {
                    margin-top: 30px;
                }
            </style>
        </head>
        <body>
            <p>Sehr geehrter Mannschaftsleiter,</p>
            
            <p>bitte überprüfen Sie erneut die hochgeladenen Daten Ihres Spielers <strong>\(player.name)</strong> mit der SID Nummer <strong>\(player.sid)</strong>. Anscheinend fehlen bei der Anmeldung:</p>
            
            <ul>
                <li>Das Profilbild des Spielers</li>
                <li>Die E-Mail-Adresse des Spielers</li>
                <li>Die Lesbarkeit des Ausweises des Spielers</li>
            </ul>
            
            <p>Bitte beachten Sie, dass sowohl das Profilbild als auch eine lesbare Kopie des Ausweises des Spielers erneut hochgeladen werden müssen. Alle Dokumente müssen gemäß der Ligaordnung hochgeladen und überprüft werden, bevor der Spieler zugelassen werden kann. Bis zur Überprüfung bleibt der Status des Spielers auf „WARTEN“ und es wird kein Bild angezeigt.</p>

            <p>Sie können sich auf <a href="https://team.oekfb.eu">team.oekfb.eu</a> einloggen, auf "Spieler bearbeiten" klicken und dort die fehlenden Dokumente hochladen. Diese Änderung ist mit keinen weiteren Kosten verbunden.</p>
            
            <p class="signature">Mit freundlichen Grüßen,<br>
            Der Österreichischer Kleinfeld Fußball Bund</p>
            <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Spieleranmeldung: \(player.sid)",
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


    
    func sendTransferRequest(req: Request, recipient: String, transfer: Transfer) throws -> EventLoopFuture<HTTPStatus> {
        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig

        // Print the SMTP configuration for debugging
        print("SMTP Configuration: \(req.application.smtp.configuration)")

        // Prepare the email content in German with a button
        let emailBody = """
        <html>
        <body style="font-family: Arial, sans-serif; font-size: 14px; color: #333;">
            <p>Hallo \(transfer.playerName),</p>

            <p>Die Mannschaft <strong>\(transfer.teamName)</strong> hat dir eine Anfrage geschickt, ihrer Mannschaft beizutreten und deine derzeitige zu verlassen. Willst du diese Anfrage annehmen?</p>

            <p>Um diese Anfrage anzunehmen oder abzulehnen, klicken Sie bitte auf den folgenden Button:</p>

            <a href="https://oekfb.eu/#/transfer/\(transfer.id ?? UUID())" style="display: inline-block; padding: 10px 20px; font-size: 16px; color: white; background-color: #007bff; text-align: center; text-decoration: none; border-radius: 5px;">Transfer Anfrage beantworten</a>
            
            <p>Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.</p>

            <p>Mit freundlichen Grüßen,<br>Österreichische Kleinfeld Fußball Bund</p>
            <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>

        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: "OEKFB Anmeldung - Transfer Anfrage",
            body: emailBody,
            isBodyHtml: true // Indicate that the body contains HTML content
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
        req.application.smtp.configuration = smtpConfig
        
        let matchDateString = formatDate(match.details.date)
        
        let emailBody = """
        <html>
        <head>
            <style>
                body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; }
            </style>
        </head>
        <body>
            <p>Sehr geehrter Mannschaftsleiter,</p>
            <p>Die gegnerische Mannschaft hat das Spiel vom <strong>\(match.details.gameday). Spieltag, am \(matchDateString)</strong> offiziell abgesagt.</p>
            <p>Sie müssen zu diesem Spieltermin nicht erscheinen. Ihrer Mannschaft wurden automatisch <strong>3 Punkte</strong> gutgeschrieben und mit 6 Toren gewonnen.</p>
            <p>Sportliche Grüße,<br>Ihr ÖKFB Team</p>
        </body>
        </html>
        """
        
        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            bcc: [EmailAddress(address: "baha@oekfb.eu", name: "Admin"), EmailAddress(address: "office@oekfb.eu", name: "Admin")],
            subject: "OEKFB Absage - Absagen Benachrichtigung",
            body: emailBody,
            isBodyHtml: true
        )
        
        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                throw Abort(.internalServerError, reason: "Failed to send email: \(error.localizedDescription)")
            }
        }
    }

    func sendPostPone(req: Request, postpone: PostponeRequest, cancellerName: String, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        let matchDateString = formatDate(match.details.date)
        
        let emailBody = """
        <html>
          <body style="font-family: Arial, sans-serif; line-height: 1.6;">
            <p>
              Die gegnerische Mannschaft <strong>\(cancellerName)</strong> bittet darum, 
              das Spiel vom <strong>\(match.details.gameday). Spieltag, am \(matchDateString)</strong> 
              offiziell zu verschieben.
            </p>
            <p>
              Bitte bestätigen oder lehnen Sie die Anfrage ab, indem Sie den folgenden Link aufrufen:
            </p>
            <p>
              <a href="https://www.oekfb.eu/#/postpone/\(postpone.id)">
                Spielverschiebung ansehen
              </a>
            </p>
          </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            bcc: [EmailAddress(address: "office@oekfb.eu", name: "Admin")],
            subject: "OEKFB Spielverlegung Anfrage",
            body: emailBody,
            isBodyHtml: true
        )
        
        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                throw Abort(.internalServerError, reason: "Failed to send email: \(error.localizedDescription)")
            }
        }
    }

    func approve(req: Request, approverName: String, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        let matchDateString = formatDate(match.details.date)
        
        let emailBody = """
        <html>
        <body>
            <p>Die gegnerische Mannschaft: <strong>\(approverName)</strong> hat Ihrer Anfrage zur Spielverlegung vom <strong>\(match.details.gameday). Spieltag, am \(matchDateString)</strong> <strong>zugestimmt</strong>.</p>
            <p>Sie müssen zu diesem Spieltermin nicht erscheinen.</p>
        </body>
        </html>
        """
        
        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            bcc: [EmailAddress(address: "office@oekfb.eu", name: "Admin")],
            subject: "OEKFB Spielverlegung Anfrage - Zusagt",
            body: emailBody,
            isBodyHtml: true
        )
        
        print("sendingto: \(recipient)")
        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                throw Abort(.internalServerError, reason: "Failed to send email: \(error.localizedDescription)")
            }
        }
    }

    func deny(req: Request, denierName: String, recipient: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        let matchDateString = formatDate(match.details.date)
        
        let emailBody = """
        <html>
        <body>
            <p>Die gegnerische Mannschaft: <strong>\(denierName)</strong> hat der Spielverlegung vom <strong>\(match.details.gameday). Spieltag, am \(matchDateString)</strong> <strong>nicht zugestimmt</strong>.</p>
            <p>Das Spiel findet wie geplant statt.</p>
        </body>
        </html>
        """
        
        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            bcc: [EmailAddress(address: "office@oekfb.eu", name: "Admin")],
            subject: "OEKFB Spielverlegung Anfrage - Abgelehnt",
            body: emailBody,
            isBodyHtml: true
        )
        
        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                throw Abort(.internalServerError, reason: "Failed to send email: \(error.localizedDescription)")
            }
        }
    }

    func informRefereeCancellation(req: Request, email: String, name: String, match: Match) throws -> EventLoopFuture<HTTPStatus> {
        req.application.smtp.configuration = smtpConfig
        
        let matchDateString = formatDate(match.details.date)

        let emailBody = """
        <html>
        <body>
            <p>Das Spiel: <strong>\(match.homeBlanket?.name ?? "Heimteam") vs \(match.awayBlanket?.name ?? "Auswärtsteam")</strong> am <strong>\(match.details.gameday). Spieltag, \(matchDateString)</strong> wurde <strong>abgesagt</strong>.</p>
            <p>Bitte prüfen Sie den Spielplan.</p>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: email)],
            subject: "OEKFB Spielabsage - \(matchDateString)",
            body: emailBody,
            isBodyHtml: true
        )

        return req.smtp.send(email).flatMapThrowing { result in
            switch result {
            case .success:
                return .ok
            case .failure(let error):
                throw Abort(.internalServerError, reason: "Failed to send email: \(error.localizedDescription)")
            }
        }
    }
}


// MARK: - EmailController: switch from "enter code" to "click link"

extension EmailController {

    func sendEmailVerificationLink(
        req: Request,
        recipient: String,
        verificationUrl: String
    ) throws -> EventLoopFuture<HTTPStatus> {

        // Apply the SMTP configuration
        req.application.smtp.configuration = smtpConfig

        print("SMTP Configuration: \(req.application.smtp.configuration)")
        print("Sending verification link to: \(recipient)")
        print("Verification URL: \(verificationUrl)")

        let subject = "OEKFB E-Mail bestätigen"

        let emailBody = """
        <!DOCTYPE html>
        <html lang="de">
        <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>\(subject)</title>
            <style>
                body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; color: #333; background-color: #f8f9fa; margin: 0; padding: 20px; }
                .container { max-width: 560px; margin: 0 auto; background: #fff; border-radius: 10px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
                h2 { margin: 0 0 10px 0; font-size: 18px; }
                p { margin: 0 0 12px 0; }
                .btn {
                    display: inline-block;
                    padding: 12px 18px;
                    border-radius: 8px;
                    background: #007bff;
                    color: #fff !important;
                    text-decoration: none;
                    font-weight: bold;
                }
                .hint { font-size: 12px; color: #6b7280; margin-top: 12px; }
                .footer { margin-top: 18px; font-size: 12px; color: #6b7280; }
                a { color: #007bff; text-decoration: none; }
                a:hover { text-decoration: underline; }
                .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; word-break: break-all; }
            </style>
        </head>
        <body>
            <div class="container">
                <h2>Österreichischer Kleinfeld Fußball Bund</h2>

                <p>Sehr geehrte Damen und Herren,</p>
                <p>bitte bestätigen Sie Ihre E-Mail-Adresse, indem Sie auf folgenden Button klicken:</p>

                <p>
                    <a class="btn" href="\(verificationUrl)">E-Mail bestätigen</a>
                </p>

                <p class="hint">
                    Falls der Button nicht funktioniert, öffnen Sie bitte diesen Link in Ihrem Browser:<br/>
                    <span class="mono">\(verificationUrl)</span>
                </p>

                <div class="footer">
                    <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, kontaktieren Sie uns bitte unter <a href="mailto:support@oekfb.eu">support@oekfb.eu</a>.</p>
                </div>
            </div>
        </body>
        </html>
        """

        let email = try Email(
            from: EmailAddress(address: "office@oekfb.eu", name: "Admin"),
            to: [EmailAddress(address: recipient)],
            subject: subject,
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

