//
//  File.swift
//  
//
//  Created by Alon Yakoby on 29.05.24.
//

import Vapor
import SwiftSMTP

final class EmailController {
    
    private let mailRepository: MailRepository
    
    init() {
        let config = EmailConfiguration(hostname: "smtp.easyname.com", email: "admin@oekfb.eu", password: "Oekfb$2024")
        self.mailRepository = MailRepository(configuration: config)
    }
    
    func sendTestEmail(req: Request) -> EventLoopFuture<String> {
        let recipient = Mail.User(name: "Alon Yakoby", email: "alon.yakoby@gmail.com")
        
        let emailResult = mailRepository.sendEmail(
            to: [recipient],
            subject: "Test Email",
            token: "12345",
            text: "This is a test email",
            html: "<h1>This is a test email</h1>",
            on: req.eventLoop
        )
        
        return emailResult.map { "Email sent successfully" }
            .flatMapErrorThrowing { error in
                return "Failed to send email: \(error.localizedDescription)"
            }
    }
}
