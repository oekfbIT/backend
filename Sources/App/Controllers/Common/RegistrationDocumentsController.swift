import Fluent
import Vapor

/// Signed mail links expose only this application's contact data and upload state.
struct RegistrationDocumentDetail: Content {
    struct Contact: Content {
        let first: String
        let last: String
        let phone: String
        let email: String
        let identificationUploaded: Bool
        init(_ value: ContactPerson?) {
            first = value?.first ?? ""; last = value?.last ?? ""
            phone = value?.phone ?? ""; email = value?.email ?? ""
            identificationUploaded = value?.identification?.isEmpty == false
        }
    }
    let id: UUID?
    let teamName: String
    let status: TeamRegistrationStatus
    let primary: Contact
    let secondary: Contact
    let customerSignedContractUploaded: Bool
    let teamLogoUploaded: Bool
    let editable: Bool
    let contractUrl: String?
    init(_ registration: TeamRegistration) {
        contractUrl = try? RegistrationFlow.contractURL().absoluteString
        id = registration.id; teamName = registration.teamName; status = registration.status
        primary = Contact(registration.primary); secondary = Contact(registration.secondary)
        customerSignedContractUploaded = registration.customerSignedContract?.isEmpty == false
        teamLogoUploaded = registration.teamLogo?.isEmpty == false
        editable = (try? RegistrationFlow.requireEditable(registration)) != nil
    }
}

final class RegistrationDocumentsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let route = routes.grouped("email-actions", "registration", ":id").grouped(ProtectedResponseMiddleware())
        route.get(use: detail)
        route.on(.POST, body: .collect(maxSize: "45mb"), use: upload)
    }

    private func requireRegistration(_ req: Request) async throws -> TeamRegistration {
        let id = try req.parameters.require("id", as: UUID.self)
        try EmailActionLink.require(req, kind: "registration", id: id)
        guard let registration = try await TeamRegistration.find(id, on: req.db),
              let requested = registration.documentsRequestedAt,
              requested > Date.viennaNow.addingTimeInterval(-30 * 24 * 60 * 60) else {
            throw Abort(.unauthorized, reason: "Dieser Upload-Link ist abgelaufen. Bitte einen neuen Link beim ÖKFB anfordern.")
        }
        return registration
    }

    func detail(_ req: Request) async throws -> RegistrationDocumentDetail {
        RegistrationDocumentDetail(try await requireRegistration(req))
    }

    struct Upload: Content {
        let primary: ContactPerson
        let secondary: ContactPerson
        let primaryIdentification: File?
        let secondaryIdentification: File?
        let signedContract: File?
        let teamLogo: File?
    }

    func upload(_ req: Request) async throws -> RegistrationDocumentDetail {
        let registration = try await requireRegistration(req)
        try RegistrationFlow.requireEditable(registration)
        let input = try req.content.decode(Upload.self)
        try RegistrationFlow.validateContact(input.primary)
        try RegistrationFlow.validateContact(input.secondary)
        let files = [input.primaryIdentification, input.secondaryIdentification, input.signedContract, input.teamLogo].compactMap { $0 }
        try files.forEach(RegistrationFlow.validateFile)
        var primary = input.primary
        var secondary = input.secondary
        // Never trust document URLs from a public request or erase existing files.
        primary.identification = registration.primary?.identification
        secondary.identification = registration.secondary?.identification
        if !files.isEmpty { try await RegistrationFlow.prepareUploads(req: req) }
        let path = "registrations/\(try registration.requireID())/\(UUID())"
        if let file = input.primaryIdentification {
            primary.identification = try await RegistrationFlow.upload(file, to: "\(path)/primary_id", req: req)
        }
        if let file = input.secondaryIdentification {
            secondary.identification = try await RegistrationFlow.upload(file, to: "\(path)/secondary_id", req: req)
        }
        if let file = input.signedContract {
            registration.customerSignedContract = try await RegistrationFlow.upload(file, to: "\(path)/contract", req: req)
        }
        if let file = input.teamLogo {
            registration.teamLogo = try await RegistrationFlow.upload(file, to: "\(path)/logo", req: req)
        }
        registration.primary = primary; registration.secondary = secondary
        if RegistrationFlow.documentsComplete(registration), registration.status == .draft { registration.status = .verified }
        try await registration.save(on: req.db)
        // Uploads stay saved if SMTP is temporarily unavailable; the admin sees failed delivery.
        if !files.isEmpty { await RegistrationFlow.documentsReceived(registration, req: req) }
        return RegistrationDocumentDetail(registration)
    }
}
