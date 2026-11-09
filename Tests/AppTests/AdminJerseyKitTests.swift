import Fluent
import FluentMongoDriver
import XCTVapor
@testable import App

final class AdminJerseyKitTests: XCTestCase {
    private func png() throws -> File {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "jersey-kit-transparent", withExtension: "png", subdirectory: "Fixtures"))
        return File(data: ByteBuffer(data: try Data(contentsOf: url)), filename: "jersey.png")
    }

    func testKitRoutesRequireAuthentication() throws {
        let app = Application(.testing); defer { app.shutdown() }
        try routes(app)
        for (method, path) in [(HTTPMethod.POST, "admin/jersey-kits/generate"),
                               (.PUT, "admin/teams/\(UUID())/jerseys/home")] {
            try app.test(method, path) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testReadOnlyAdministratorCannotGenerateOrSave() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let user = User(userID: "reader", type: .admin, firstName: "Test", lastName: "Admin", email: "test@example.test", passwordHash: "unused")
        user.permissions = [.teamsRead]
        let req = Request(application: app, on: app.eventLoopGroup.next())
        req.auth.login(user)
        do {
            _ = try await PermissionMiddleware(.teamsUpdate).respond(to: req, chainingTo: KitTestResponder())
            XCTFail("Expected permission denial")
        } catch let error as AbortError { XCTAssertEqual(error.status, .forbidden) }
    }

    func testGenerationReturnsPNGWithoutDatabaseOrStorageAndMissingImageFails() throws {
        let app = Application(.testing); defer { app.shutdown() }
        let image = try png()
        app.jerseyKitGenerator = KitTestGenerator(image: image)
        AdminController(path: "admin").setupJerseyKitRoutes(on: app.grouped("admin"))
        try app.test(.POST, "admin/jersey-kits/generate", beforeRequest: {
            try $0.content.encode(AdminController.GenerateJerseyKitRequest(image: image), as: .formData)
        }) {
            XCTAssertEqual($0.status, .ok)
            XCTAssertEqual($0.headers.contentType, .png)
            XCTAssertEqual($0.headers.first(name: "Cache-Control"), "no-store")
            XCTAssertEqual(Data(buffer: $0.body), Data(buffer: image.data))
        }
        struct MissingImage: Content { let other: String }
        try app.test(.POST, "admin/jersey-kits/generate", beforeRequest: {
            try $0.content.encode(MissingImage(other: "missing"), as: .formData)
        }) { XCTAssertEqual($0.status, .badRequest) }
    }

    func testSavingRejectsUnknownSideBeforeStorageOrDatabaseAccess() throws {
        let app = Application(.testing); defer { app.shutdown() }
        AdminController(path: "admin").setupJerseyKitRoutes(on: app.grouped("admin"))
        try app.test(.PUT, "admin/teams/\(UUID())/jerseys/other") { XCTAssertEqual($0.status, .badRequest) }
    }

    func testApprovalUpdatesOnlySelectedJerseyAndRejectsStaleReplacements() async throws {
        guard let port = Environment.get("JERSEY_KIT_TEST_MONGO_PORT"), Int(port) != nil else {
            throw XCTSkip("Set JERSEY_KIT_TEST_MONGO_PORT to an isolated local MongoDB port.")
        }
        let app = Application(.testing)
        let databaseName = "oekfb_kit_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(databaseName)"), as: .mongo)
        defer { try? (app.db as? MongoDatabaseRepresentable)?.raw.drop().wait(); app.shutdown() }
        let storageClient = KitStorageClient(eventLoop: app.eventLoopGroup.next())
        app.firebaseManager = FirebaseManager(client: storageClient, apiKey: "test", email: "test@example.test", password: "test", projectId: "test")
        AdminController(path: "admin").setupJerseyKitRoutes(on: app.grouped("admin"))
        let team = Team(id: UUID(), sid: "KITTEST", userId: nil, leagueId: nil, leagueCode: nil, points: 7,
            coverimg: "", logo: "logo", teamName: "Kit Test", foundationYear: nil, membershipSince: nil, averageAge: nil,
            coach: nil, trikot: .init(home: "old-home", away: "old-away"), balance: 123,
            usremail: nil, usrpass: nil, usrtel: nil)
        try await team.create(on: app.db)
        let id = try team.requireID()
        let file = try png()
        try app.test(.PUT, "admin/teams/\(id)/jerseys/home", beforeRequest: {
            try $0.content.encode(AdminController.SaveTeamJerseyRequest(image: file, expectedImageUrl: "old-home"), as: .formData)
        }) { XCTAssertEqual($0.status, .ok) }
        let savedResult = try await Team.find(id, on: app.db)
        let saved = try XCTUnwrap(savedResult)
        XCTAssertNotEqual(saved.trikot.home, "old-home")
        XCTAssertEqual(saved.trikot.away, "old-away")
        XCTAssertEqual(saved.balance, 123)
        XCTAssertEqual(saved.points, 7)
        let uploads = storageClient.uploadCount
        try app.test(.PUT, "admin/teams/\(id)/jerseys/home", beforeRequest: {
            try $0.content.encode(AdminController.SaveTeamJerseyRequest(image: file, expectedImageUrl: "old-home"), as: .formData)
        }) { XCTAssertEqual($0.status, .conflict) }
        XCTAssertEqual(storageClient.uploadCount, uploads)
        storageClient.failUpload = true
        try app.test(.PUT, "admin/teams/\(id)/jerseys/away", beforeRequest: {
            try $0.content.encode(AdminController.SaveTeamJerseyRequest(image: file, expectedImageUrl: "old-away"), as: .formData)
        }) { XCTAssertEqual($0.status, .badGateway) }
        let afterFailureResult = try await Team.find(id, on: app.db)
        let afterFailure = try XCTUnwrap(afterFailureResult)
        XCTAssertEqual(afterFailure.trikot.away, "old-away")
    }
}

private struct KitTestGenerator: JerseyKitGenerating {
    let image: File
    func generate(image: File) async throws -> File { self.image }
}

private struct KitTestResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response { Response(status: .ok) }
}

private final class KitStorageClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    var uploadCount = 0
    var failUpload = false
    init(eventLoop: EventLoop) { self.eventLoop = eventLoop }
    func delegating(to eventLoop: EventLoop) -> Client { self }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let data: [String: Any]
        if request.url.host == "identitytoolkit.googleapis.com" {
            data = ["idToken": "test-token"]
        } else {
            uploadCount += 1
            if failUpload { return eventLoop.makeSucceededFuture(.init(status: .internalServerError)) }
            data = ["name": "kit", "bucket": "test", "generation": "1", "metageneration": "1", "contentType": "image/png",
                    "timeCreated": "now", "updated": "now", "storageClass": "STANDARD", "size": "1", "md5Hash": "test", "downloadTokens": "test-download-token"]
        }
        return eventLoop.makeSucceededFuture(.init(status: .ok, headers: ["Content-Type": "application/json"],
            body: ByteBuffer(data: try! JSONSerialization.data(withJSONObject: data))))
    }
}
