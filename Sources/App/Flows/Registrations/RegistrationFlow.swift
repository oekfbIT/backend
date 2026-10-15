import Fluent
import Vapor

/// Shared rules for the website, application and administrator entry points.
enum RegistrationFlow {
    static func requireEditable(_ registration: TeamRegistration) throws {
        guard registration.team == nil,
              [.draft, .verified, .paid].contains(registration.status) else {
            throw Abort(.conflict, reason: "Diese Anmeldung ist bereits abgeschlossen oder wird gerade freigegeben.")
        }
    }

    static func validateContact(_ contact: ContactPerson?) throws {
        guard let contact,
              !contact.first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contact.last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contact.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contact.email.contains("@") else {
            throw Abort(.badRequest, reason: "Bitte Namen, Telefonnummer und E-Mail beider Kontaktpersonen angeben.")
        }
    }

    static func documentsComplete(_ registration: TeamRegistration) -> Bool {
        registration.customerSignedContract?.isEmpty == false &&
        registration.primary?.identification?.isEmpty == false &&
        registration.secondary?.identification?.isEmpty == false
    }

    static func validateFile(_ file: File) throws {
        let ext = (file.filename as NSString).pathExtension.lowercased()
        guard ["pdf", "jpg", "jpeg", "png"].contains(ext),
              file.data.readableBytes > 0, file.data.readableBytes <= 10 * 1024 * 1024 else {
            throw Abort(.badRequest, reason: "Bitte PDF, JPG oder PNG mit maximal 10 MB hochladen.")
        }
        let bytes = Array(file.data.readableBytesView.prefix(8))
        let valid = ext == "pdf" ? bytes.starts(with: [37, 80, 68, 70, 45]) :
            ext == "png" ? bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) :
            bytes.starts(with: [255, 216, 255])
        guard valid else { throw Abort(.badRequest, reason: "Dateiinhalt und Dateityp stimmen nicht überein.") }
    }

    static func sendWelcome(req: Request, registration: TeamRegistration?) throws -> EventLoopFuture<HTTPStatus> {
        guard let registration else { throw Abort(.notFound) }
        return req.eventLoop.makeFutureWithTask {
            var deliveryError: Error?
            do {
                _ = try await EmailController().sendWelcomeMail(req: req, recipient: registration.primary?.email ?? "", registration: registration).get()
                registration.isWelcomeEmailSent = true
                try await registration.save(on: req.db)
            } catch {
                registration.isWelcomeEmailSent = false
                try await registration.save(on: req.db)
                req.logger.error("Registration welcome email delivery failed: \(error)")
                deliveryError = error
            }
            if registration.emailDeliveries?["adminRequestReceived"] != "sent" {
                try? await notify(registration, event: "adminRequestReceived", req: req,
                    recipient: Environment.get("REGISTRATION_ADMIN_EMAIL") ?? "office@oekfb.eu",
                    subject: "ÖKFB – Neue Mannschaftsanmeldung",
                    body: "<p>Eine neue Mannschaftsanmeldung liegt vor: \(try registration.requireID()). Bitte in der Registrierungsübersicht prüfen.</p>")
            }
            if let deliveryError { throw deliveryError }
            return .ok
        }
    }

    static func documentsReceived(_ registration: TeamRegistration, req: Request) async {
        guard documentsComplete(registration) else { return }
        try? await notify(registration, event: "documentsReceived", req: req,
            subject: "ÖKFB – Unterlagen eingegangen", body: "<p>Ihre Unterlagen wurden gespeichert und werden von der Administration geprüft. Eine Mannschaft wird erst nach Freigabe angelegt.</p>")
        try? await notify(registration, event: "adminDocumentsReceived", req: req,
            recipient: Environment.get("REGISTRATION_ADMIN_EMAIL") ?? "office@oekfb.eu",
            subject: "ÖKFB – Anmeldung zur Prüfung", body: "<p>Neue Unterlagen zur Anmeldung \(registration.id?.uuidString ?? ""). Bitte in der Registrierungsübersicht prüfen.</p>")
    }

    static func notify(_ registration: TeamRegistration, event: String, req: Request,
                       recipient: String? = nil, subject: String, body: String) async throws {
        var deliveries = registration.emailDeliveries ?? [:]
        deliveries[event] = "pending"
        registration.emailDeliveries = deliveries
        try await registration.save(on: req.db)
        do {
            _ = try await EmailController().sendRegistrationNotice(req: req,
                recipient: recipient ?? registration.primary?.email ?? "", subject: subject, body: body).get()
            deliveries[event] = "sent"
            registration.emailDeliveries = deliveries
            try await registration.save(on: req.db)
        } catch {
            deliveries[event] = "failed"
            registration.emailDeliveries = deliveries
            try await registration.save(on: req.db)
            throw error
        }
    }
}

/// Dependency injection for registration mail transport in isolated integration tests.
struct RegistrationMailTransportKey: StorageKey {
    typealias Value = (Request, String) -> EventLoopFuture<HTTPStatus>
}

import FluentMongoDriver
import MongoKitten

extension RegistrationFlow {
    /// Receipt and credit share one atomic write, making network retries safe.
    static func recordPayment(_ registration: TeamRegistration, amount: Double, paymentID: UUID, req: Request) async throws -> TeamRegistration {
        guard let mongo = req.db as? MongoDatabaseRepresentable else { throw Abort(.serviceUnavailable) }
        let id = try registration.requireID()
        let key = try BSONEncoder().encodePrimitive(id)!
        let receipt = "paymentReceipts.\(paymentID.uuidString.lowercased())"
        let collection = mongo.raw[TeamRegistration.schema]
        let reply = try await collection.findOneAndUpdate(where: ["_id": key, "team": Null(), receipt: Null(),
            "status": ["$in": ["draft", "verified", "paid"]] as Document],
            to: ["$inc": ["paidAmount": amount] as Document, "$set": [receipt: amount] as Document]).execute().get()
        guard reply.ok == 1 else { throw reply }
        if reply.value == nil {
            guard let stored = try await collection.findOne(["_id": key]).get(),
                  let receipts = stored["paymentReceipts"] as? Document,
                  let previous = receipts[paymentID.uuidString.lowercased()] as? Double,
                  previous == amount else {
                throw Abort(.conflict, reason: "Zahlung konnte nicht verbucht werden. Bitte Anmeldung neu laden.")
            }
        }
        guard let updated = try await TeamRegistration.find(id, on: req.db) else { throw Abort(.notFound) }
        updated.status = (updated.paidAmount ?? -1) >= 0 ? .paid : (documentsComplete(updated) ? .verified : .draft)
        try await updated.save(on: req.db)
        return updated
    }
}

extension RegistrationFlow {
    static func contractURL() throws -> URL {
        guard let raw = Environment.get("REGISTRATION_CONTRACT_URL"), let url = URL(string: raw),
              url.scheme == "https", url.host != nil else {
            throw Abort(.serviceUnavailable, reason: "REGISTRATION_CONTRACT_URL ist nicht konfiguriert.")
        }
        return url
    }

    static func homepageURL() throws -> String {
        let raw = Environment.get("REGISTRATION_WEB_BASE_URL") ?? "https://www.oekfb.eu"
        guard let url = URL(string: raw), url.host != nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")) else {
            throw Abort(.serviceUnavailable, reason: "REGISTRATION_WEB_BASE_URL ist ungültig.")
        }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}

struct RegistrationFileTransportKey: StorageKey {
    typealias Value = (Request, File, String) -> EventLoopFuture<String>
}

extension RegistrationFlow {
    static func prepareUploads(req: Request) async throws {
        if req.application.storage[RegistrationFileTransportKey.self] == nil {
            try await req.application.firebaseManager.authenticate().get()
        }
    }

    static func upload(_ file: File, to path: String, req: Request) async throws -> String {
        try validateFile(file)
        if let transport = req.application.storage[RegistrationFileTransportKey.self] {
            return try await transport(req, file, path).get()
        }
        return try await req.application.firebaseManager.uploadFile(file: file, to: path).get()
    }
}

extension RegistrationFlow {
    /// A verified account may continue the request made with its own email on the website.
    static func claimWebsiteRegistrations(for user: User, req: Request) async throws {
        guard user.type == .team, user.verified == true else { return }
        let owner = try user.requireID()
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pending = try await TeamRegistration.query(on: req.db)
            .filter(\.$user == nil).filter(\.$team == nil)
            .filter(\.$status ~~ [.draft, .verified, .paid]).all()
        for registration in pending where registration.primary?.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email {
            try await TeamRegistration.query(on: req.db).filter(\.$id == registration.requireID()).filter(\.$user == nil)
                .set(\.$user, to: owner).update()
        }
    }
}
