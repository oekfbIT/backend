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
}
