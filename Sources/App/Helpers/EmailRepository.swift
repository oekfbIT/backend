////
////
////  Copyright © 2023.
////  Alon Yakobichvili
////  All rights reserved.
////
//  
//
//import Foundation
//import SwiftSMTP
//import NIO
//
//import SwiftSMTP
//
//class MailRepository {
//    
//    private let smtp: SMTP
//    private let from: Mail.User
//    
//    init(configuration: EmailConfiguration) {
//        self.smtp = configuration.smtp
//        self.from = Mail.User(name: "Company Support", email: configuration.email)
//    }
//    
//    func sendEmail(to: [Mail.User], subject: String, token: String, text: String, html: String, on eventLoop: EventLoop) -> EventLoopFuture<Void> {
//        let htmlPart = Attachment(htmlContent: html)
//        let email = Mail(from: from, to: to, subject: subject, text: text, attachments: [htmlPart])
//        
//        let promise = eventLoop.makePromise(of: Void.self)
//        
//        smtp.sendWithResult(email) { result in
//            switch result {
//            case .success:
//                print("Email with attachment sent successfully. Activation ID: \(token)")
//                promise.succeed(())
//            case .failure(let error):
//                print("Activation ID: \(token): Failed to send email: \(error). ")
//                promise.fail(error)
//            }
//        }
//        
//        return promise.futureResult
//    }
//
//    func sendEmailAttachment(to: [Mail.User], token: String, subject: String, text: String, attachments: [Attachment], on eventLoop: EventLoop) -> EventLoopFuture<Void> {
//        let email = Mail(from: from, to: to, subject: subject, text: text, attachments: attachments)
//        
//        let promise = eventLoop.makePromise(of: Void.self)
//        
//        smtp.sendWithResult(email) { result in
//            switch result {
//            case .success:
//                print("Email with attachment sent successfully. Activation ID: \(token)")
//                promise.succeed(())
//            case .failure(let error):
//                print("Failed to send email with attachment: \(error)")
//                promise.fail(error)
//            }
//        }
//        
//        return promise.futureResult
//    }
//}
//
//// Extension for the SMTP class
//extension SMTP {
//    func sendWithResult(_ mail: Mail, completion: @escaping (Result<Void, Error>) -> Void) {
//        self.send(mail) { error in
//            if let error = error {
//                completion(.failure(error))
//            } else {
//                completion(.success(()))
//            }
//        }
//    }
//}
//
//extension Attachment {
//    init(htmlContent: String) {
//        let data = htmlContent.data(using: .utf8) ?? Data()
//        self.init(data: data, mime: "text/html", name: "HTML Email Content", inline: true)
//    }
//}
