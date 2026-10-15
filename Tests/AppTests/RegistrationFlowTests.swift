import XCTVapor
@testable import App

final class RegistrationFlowTests: XCTestCase {
    func testLifecycleLocksAndDocumentRequirements() throws {
        let registration = TeamRegistration(teamName: "Test", status: .draft, bundesland: .wien, initialPassword: nil, teamLogo: nil)
        XCTAssertNoThrow(try RegistrationFlow.requireEditable(registration))
        XCTAssertFalse(RegistrationFlow.documentsComplete(registration))
        registration.primary = ContactPerson(first: "A", last: "B", phone: "123", email: "a@example.test", identification: "primary")
        registration.secondary = ContactPerson(first: "C", last: "D", phone: "456", email: "b@example.test", identification: "secondary")
        XCTAssertFalse(RegistrationFlow.documentsComplete(registration))
        registration.customerSignedContract = "contract"
        XCTAssertTrue(RegistrationFlow.documentsComplete(registration))
        for state: TeamRegistrationStatus in [.approved, .rejected, .completed, .teamCustomization] {
            registration.status = state
            XCTAssertThrowsError(try RegistrationFlow.requireEditable(registration))
        }
        registration.status = .paid
        XCTAssertNoThrow(try RegistrationFlow.requireEditable(registration))
        registration.team = UUID()
        XCTAssertThrowsError(try RegistrationFlow.requireEditable(registration))
    }

    func testUploadValidationRejectsDisguisedFiles() throws {
        let pdf = File(data: ByteBuffer(string: "%PDF-1.7 test"), filename: "contract.pdf")
        XCTAssertNoThrow(try RegistrationFlow.validateFile(pdf))
        XCTAssertThrowsError(try RegistrationFlow.validateFile(File(data: ByteBuffer(string: "<script>"), filename: "contract.pdf")))
        XCTAssertThrowsError(try RegistrationFlow.validateFile(File(data: ByteBuffer(string: "%PDF-1.7"), filename: "contract.html")))
        XCTAssertThrowsError(try RegistrationFlow.validateFile(File(data: ByteBuffer(), filename: "contract.pdf")))
    }

    func testPublicDetailContainsFlagsWithoutDocumentURLsOrPasswords() throws {
        let registration = TeamRegistration(teamName: "Test", status: .draft, bundesland: .wien, initialPassword: "secret", customerSignedContract: "private-contract", teamLogo: nil)
        registration.primary = ContactPerson(first: "A", last: "B", phone: "123", email: "a@example.test", identification: "private-id")
        let response = RegistrationDocumentDetail(registration)
        let json = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
        XCTAssertTrue(response.primary.identificationUploaded)
        XCTAssertTrue(response.customerSignedContractUploaded)
        XCTAssertFalse(json.contains("private-id"))
        XCTAssertFalse(json.contains("private-contract"))
        XCTAssertFalse(json.contains("secret"))
    }
}

import Fluent
import FluentMongoDriver
import MongoKitten

extension RegistrationFlowTests {
    private func withDatabase(_ run: (Application) async throws -> Void) async throws {
        guard let port = Environment.get("REGISTRATION_TEST_MONGO_PORT") else {
            throw XCTSkip("Set REGISTRATION_TEST_MONGO_PORT to a local test MongoDB port.")
        }
        let app = Application(.testing)
        let name = "oekfb_registration_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(name)"), as: .mongo)
        app.storage[RegistrationMailTransportKey.self] = { req, _ in req.eventLoop.makeSucceededFuture(.ok) }
        let mongo = (app.db as! MongoDatabaseRepresentable).raw
        do {
            try await run(app)
            try await mongo.drop().get()
            app.shutdown()
        } catch {
            try? await mongo.drop().get()
            app.shutdown()
            throw error
        }
    }

    func testWelcomeDeliveryFlagReflectsFailureAndRetry() async throws {
        try await withDatabase { app in
            let registration = TeamRegistration(teamName: "Mail test", status: .draft, bundesland: .wien, initialPassword: "test", teamLogo: nil)
            try await registration.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            app.storage[RegistrationMailTransportKey.self] = { req, _ in req.eventLoop.makeFailedFuture(Abort(.badGateway)) }
            do { _ = try await RegistrationFlow.sendWelcome(req: req, registration: registration).get(); XCTFail("Failed mail accepted") } catch {}
            let failed = try await TeamRegistration.find(registration.id, on: app.db)
            XCTAssertEqual(failed?.isWelcomeEmailSent, false)
            app.storage[RegistrationMailTransportKey.self] = { req, _ in req.eventLoop.makeSucceededFuture(.ok) }
            _ = try await RegistrationFlow.sendWelcome(req: req, registration: registration).get()
            let delivered = try await TeamRegistration.find(registration.id, on: app.db)
            XCTAssertEqual(delivered?.isWelcomeEmailSent, true)
            XCTAssertEqual(delivered?.emailDeliveries?["adminRequestReceived"], "sent")
        }
    }

    func testDocumentRoutesRejectMissingTokenAndExpiredLink() async throws {
        try await withDatabase { app in
            try app.register(collection: RegistrationDocumentsController())
            try app.test(.GET, "/email-actions/registration/\(UUID())") { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try app.test(.POST, "/email-actions/registration/\(UUID())") { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testAppContactEditPreservesStoredIDsAndLocksFinalizedRegistration() async throws {
        try await withDatabase { app in
            let user = User(userID: "test", type: .team, firstName: "Test", lastName: "Owner", verified: true, email: "test@example.test", passwordHash: "test")
            try await user.save(on: app.db)
            let registration = TeamRegistration(primary: ContactPerson(first: "Old", last: "Name", phone: "123", email: "test@example.test", identification: "stored-primary"),
                secondary: ContactPerson(first: "Second", last: "Name", phone: "456", email: "second@example.test", identification: "stored-secondary"),
                teamName: "Test", status: .draft, bundesland: .wien, initialPassword: "secret", customerSignedContract: "stored-contract", teamLogo: nil, user: user.id)
            try await registration.save(on: app.db)
            app.patch("test", ":registrationId") { req async throws -> TeamApplicationDetail in
                req.auth.login(user)
                return try await AppController(path: "app").updateTeamRegistration(req: req)
            }
            try app.test(.PATCH, "/test/\(try registration.requireID())", beforeRequest: { req in
                try req.content.encode(UpdateTeamRegistrationRequest(primary: ContactPerson(first: "Changed", last: "Name", phone: "123", email: "test@example.test", identification: nil)))
            }, afterResponse: { response in XCTAssertEqual(response.status, .ok) })
            let changed = try await TeamRegistration.find(registration.id, on: app.db)
            XCTAssertEqual(changed?.primary?.first, "Changed")
            XCTAssertEqual(changed?.primary?.identification, "stored-primary")
            XCTAssertEqual(changed?.secondary?.identification, "stored-secondary")
            XCTAssertEqual(changed?.customerSignedContract, "stored-contract")
            registration.status = .approved
            try await registration.save(on: app.db)
            try app.test(.PATCH, "/test/\(try registration.requireID())", beforeRequest: { req in
                try req.content.encode(UpdateTeamRegistrationRequest(teamName: "Changed again"))
            }, afterResponse: { response in XCTAssertEqual(response.status, .conflict) })
        }
    }
}

extension RegistrationFlowTests {
    func testApprovalCreatesOneLinkedTeamAndKeepsExistingAccountPassword() async throws {
        try await withDatabase { app in
            let user = User(userID: "existing", type: .team, firstName: "Test", lastName: "Owner", verified: true, email: "existing@example.test", passwordHash: "unchanged-hash")
            try await user.save(on: app.db)
            let league = League(state: .wien, teamcount: 8, code: "TEST", name: "Test league", visibility: false)
            try await league.save(on: app.db)
            let primary = ContactPerson(first: "Test", last: "Owner", phone: "123", email: user.email, identification: "primary")
            let registration = TeamRegistration(primary: primary, secondary: primary, teamName: "Test team", status: .paid,
                bundesland: .wien, initialPassword: "must-not-send", assignedLeague: league.id,
                customerSignedContract: "contract", teamLogo: nil, paidAmount: 0, user: user.id)
            try await registration.save(on: app.db)
            app.storage[RegistrationMailTransportKey.self] = { req, method in
                XCTAssertNotEqual(method, "sendTeamLogin", "An existing account must not receive a generated password")
                return req.eventLoop.makeSucceededFuture(.ok)
            }
            let admin = AdminController(path: "admin")
            app.post("confirm", ":id", use: admin.confirm)
            app.post("complete", ":id", use: admin.startTeamCustomization)
            for action in ["confirm", "confirm", "complete"] {
                try app.test(.POST, "/\(action)/\(try registration.requireID())") { response in XCTAssertEqual(response.status, .ok) }
            }
            let count = try await Team.query(on: app.db).count()
            let updated = try await TeamRegistration.find(registration.id, on: app.db)
            let unchanged = try await User.find(user.id, on: app.db)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(updated?.team, registration.id)
            XCTAssertEqual(updated?.status, .approved)
            XCTAssertEqual(updated?.isLoginDataSent, true)
            XCTAssertEqual(unchanged?.passwordHash, "unchanged-hash")
            // Legacy approvals did not save their team link. Repair must find the existing team.
            updated?.team = nil
            try await updated?.save(on: app.db)
            try app.test(.POST, "/confirm/\(try registration.requireID())") { response in XCTAssertEqual(response.status, .ok) }
            let repaired = try await TeamRegistration.find(registration.id, on: app.db)
            let repairedCount = try await Team.query(on: app.db).count()
            XCTAssertEqual(repaired?.team, registration.id)
            XCTAssertEqual(repairedCount, 1)
        }
    }

    func testInitialRequestDoesNotCreateAccountOrTeamAndRetryDoesNotDuplicate() async throws {
        try await withDatabase { app in
            app.post("register", use: TeamRegistrationController(path: "registrations").register)
            let contact = ContactPerson(first: "Test", last: "Contact", phone: "123", email: "test@example.test", identification: "untrusted-url")
            let input = TeamRegistrationRequest(primaryContact: contact, secondaryContact: contact, teamName: "New team", verein: nil,
                bundesland: .wien, type: .privat, acceptedAGB: true, referCode: "", initialPassword: "untrusted-password")
            for _ in 0..<2 {
                try app.test(.POST, "/register", beforeRequest: { req in try req.content.encode(input) }, afterResponse: { response in
                    XCTAssertEqual(response.status, .ok)
                })
            }
            let registrations = try await TeamRegistration.query(on: app.db).all()
            let teams = try await Team.query(on: app.db).count()
            let users = try await User.query(on: app.db).count()
            XCTAssertEqual(registrations.count, 1)
            XCTAssertEqual(teams, 0)
            XCTAssertEqual(users, 0)
            XCTAssertNil(registrations.first?.primary?.identification)
            XCTAssertNotEqual(registrations.first?.initialPassword, "untrusted-password")
            XCTAssertEqual(registrations.first?.isWelcomeEmailSent, true)
        }
    }
}

extension RegistrationFlowTests {
    func testPaymentRetryCreditsOnlyOnceAndRejectsChangedAmount() async throws {
        try await withDatabase { app in
            let registration = TeamRegistration(teamName: "Payment test", status: .verified, bundesland: .wien,
                initialPassword: "test", assignedLeague: UUID(), teamLogo: nil, paidAmount: -100)
            try await registration.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let receipt = UUID()
            _ = try await RegistrationFlow.recordPayment(registration, amount: 100, paymentID: receipt, req: req)
            let updated = try await RegistrationFlow.recordPayment(registration, amount: 100, paymentID: receipt, req: req)
            XCTAssertEqual(updated.paidAmount, 0)
            XCTAssertEqual(updated.status, .paid)
            do {
                _ = try await RegistrationFlow.recordPayment(registration, amount: 200, paymentID: receipt, req: req)
                XCTFail("Same receipt accepted a different amount")
            } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
        }
    }

    func testAppInitialApplicationAllowsDeferredDocumentsAndRequiresVerifiedEmail() async throws {
        try await withDatabase { app in
            let user = User(userID: "team", type: .team, firstName: "Test", lastName: "Owner", verified: false, email: "team@example.test", passwordHash: "test")
            try await user.save(on: app.db)
            app.post("apply") { req async throws -> TeamAppApplicationResponse in
                req.auth.login(user)
                return try await AppController(path: "app").applyTeamApplication(req: req)
            }
            let contact = ContactPerson(first: "Test", last: "Owner", phone: "123", email: user.email, identification: nil)
            let input = TeamAppApplicationRequest(userid: try user.requireID(), teamName: "App team", verein: nil, bundesland: .wien,
                primary: contact, secondary: contact, primaryIdentification: nil, secondaryIdentification: nil, signedContract: nil, teamLogo: nil)
            try app.test(.POST, "/apply", beforeRequest: { req in try req.content.encode(input, as: .formData) }, afterResponse: { response in
                XCTAssertEqual(response.status, .forbidden)
            })
            user.verified = true
            try await user.save(on: app.db)
            try app.test(.POST, "/apply", beforeRequest: { req in try req.content.encode(input, as: .formData) }, afterResponse: { response in
                XCTAssertEqual(response.status, .ok)
            })
            let registrations = try await TeamRegistration.query(on: app.db).all()
            XCTAssertEqual(registrations.count, 1)
            XCTAssertEqual(registrations.first?.user, user.id)
            XCTAssertNil(registrations.first?.customerSignedContract)
            XCTAssertEqual(registrations.first?.isWelcomeEmailSent, true)
        }
    }

    func testVerificationReplayAndExpiredToken() async throws {
        try await withDatabase { app in
            let user = User(userID: "verify", type: .team, firstName: "Test", lastName: "Owner", verified: false, email: "verify@example.test", passwordHash: "test")
            try await user.save(on: app.db)
            let verification = VerificationCode(code: "long-test-token", userid: user.id, email: user.email, status: .sent)
            try await verification.save(on: app.db)
            app.get("verify", ":code", use: AppController(path: "app").verifyEmailByCode)
            for _ in 0..<2 {
                try app.test(.GET, "/verify/long-test-token") { response in XCTAssertEqual(response.status, .ok) }
            }
            verification.created = Date().addingTimeInterval(-25 * 60 * 60)
            try await verification.save(on: app.db)
            try app.test(.GET, "/verify/long-test-token") { response in XCTAssertEqual(response.status, .badRequest) }
        }
    }
}

extension RegistrationFlowTests {
    func testSignedDocumentUploadPersistsFilesNotifiesAndExpires() async throws {
        let previousSecret = Environment.get("EMAIL_ACTION_SECRET")
        setenv("EMAIL_ACTION_SECRET", String(repeating: "test", count: 16), 1)
        defer {
            if let previousSecret { setenv("EMAIL_ACTION_SECRET", previousSecret, 1) }
            else { unsetenv("EMAIL_ACTION_SECRET") }
        }
        try await withDatabase { app in
            try app.register(collection: RegistrationDocumentsController())
            app.storage[RegistrationFileTransportKey.self] = { req, _, path in
                req.eventLoop.makeSucceededFuture("https://storage.example.test/\(path)")
            }
            let contact = ContactPerson(first: "First", last: "Last", phone: "123", email: "contact@example.test", identification: nil)
            let registration = TeamRegistration(primary: contact, secondary: contact, teamName: "Upload test", status: .draft,
                bundesland: .wien, initialPassword: "secret", teamLogo: nil)
            registration.documentsRequestedAt = Date()
            try await registration.save(on: app.db)
            let id = try registration.requireID()
            let token = try EmailActionLink.token(kind: "registration", id: id)
            let headers = HTTPHeaders([("X-Email-Action-Token", token)])
            let file = File(data: ByteBuffer(string: "%PDF-1.7 fixture"), filename: "test.pdf")
            let body = RegistrationDocumentsController.Upload(primary: contact, secondary: contact,
                primaryIdentification: file, secondaryIdentification: file, signedContract: file, teamLogo: nil)
            try app.test(.POST, "/email-actions/registration/\(id)", headers: headers, beforeRequest: { req in
                try req.content.encode(body, as: .formData)
            }, afterResponse: { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertFalse(response.body.string.contains("storage.example.test"))
            })
            let stored = try await TeamRegistration.find(id, on: app.db)
            let updated = try XCTUnwrap(stored)
            XCTAssertTrue(RegistrationFlow.documentsComplete(updated))
            XCTAssertEqual(updated.status, .verified)
            XCTAssertEqual(updated.emailDeliveries?["documentsReceived"], "sent")
            XCTAssertEqual(updated.emailDeliveries?["adminDocumentsReceived"], "sent")
            updated.documentsRequestedAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
            try await updated.save(on: app.db)
            try app.test(.GET, "/email-actions/registration/\(id)", headers: headers) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            let teams = try await Team.query(on: app.db).count()
            XCTAssertEqual(teams, 0)
        }
    }
}

extension RegistrationFlowTests {
    func testOnlyVerifiedMatchingAccountCanContinueWebsiteRequest() async throws {
        try await withDatabase { app in
            let contact = ContactPerson(first: "Test", last: "Contact", phone: "123", email: "website@example.test", identification: nil)
            let registration = TeamRegistration(primary: contact, secondary: contact, teamName: "Website team", status: .draft, bundesland: .wien, initialPassword: "test", teamLogo: nil)
            try await registration.save(on: app.db)
            let user = User(userID: "test", type: .team, firstName: "Test", lastName: "Contact", verified: false, email: contact.email, passwordHash: "existing")
            try await user.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            try await RegistrationFlow.claimWebsiteRegistrations(for: user, req: req)
            let unverified = try await TeamRegistration.find(registration.id, on: app.db)
            XCTAssertNil(unverified?.user)
            user.verified = true
            try await user.save(on: app.db)
            try await RegistrationFlow.claimWebsiteRegistrations(for: user, req: req)
            let verified = try await TeamRegistration.find(registration.id, on: app.db)
            XCTAssertEqual(verified?.user, user.id)
            XCTAssertNil(verified?.team)
        }
    }

    func testPaymentIdDecodesFromFrontendSnakeCase() throws {
        let id = UUID()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = Data("{\"paid_amount\":100,\"payment_id\":\"\(id)\"}".utf8)
        let payment = try decoder.decode(AdminController.UpdatePaymentRequest.self, from: json)
        XCTAssertEqual(payment.paymentId, id)
    }
}
