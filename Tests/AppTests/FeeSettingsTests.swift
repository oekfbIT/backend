import XCTVapor
import Fluent
import FluentMongoDriver
import MongoKitten
@testable import App

final class FeeSettingsTests: XCTestCase {
    func testValidationAndCancellationTiers() throws {
        var amounts = FeeSettings.defaults
        XCTAssertNoThrow(try FeeSettings.validate(amounts))
        amounts["playerRegistration"] = 575
        XCTAssertNoThrow(try FeeSettings.validate(amounts))
        amounts["playerRegistration"] = 0
        XCTAssertNoThrow(try FeeSettings.validate(amounts))
        amounts["playerRegistration"] = -1
        XCTAssertThrowsError(try FeeSettings.validate(amounts))
        amounts = FeeSettings.defaults
        amounts.removeValue(forKey: "overdraft")
        XCTAssertThrowsError(try FeeSettings.validate(amounts))
        amounts = FeeSettings.defaults
        amounts["inventedFee"] = 100
        XCTAssertThrowsError(try FeeSettings.validate(amounts))
        XCTAssertEqual(try FeeKey.cancellation(1), .matchCancellationFirst)
        XCTAssertEqual(try FeeKey.cancellation(2), .matchCancellationSecond)
        XCTAssertEqual(try FeeKey.cancellation(3), .matchCancellationThird)
        XCTAssertThrowsError(try FeeKey.cancellation(0))
        XCTAssertThrowsError(try FeeKey.cancellation(4))
    }

    private func withMongo(_ run: (Application, MongoDatabase) async throws -> Void) async throws {
        guard let port = Environment.get("FEE_TEST_MONGO_PORT"), Int(port) != nil else {
            throw XCTSkip("Set FEE_TEST_MONGO_PORT to an isolated local MongoDB port.")
        }
        let app = Application(.testing)
        app.logger.logLevel = .critical
        let name = "oekfb_fee_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(name)"), as: .mongo)
        let mongo = (app.db as! MongoDatabaseRepresentable).raw
        do {
            try await run(app, mongo)
            try await mongo.drop().get()
            app.shutdown()
        } catch {
            try? await mongo.drop().get()
            app.shutdown()
            throw error
        }
    }

    func testSeedUpdateConflictHistoryAndMissingSettings() async throws {
        try await withMongo { app, mongo in
            let service = FeeService(database: app.db)
            do { _ = try await service.read(); XCTFail("Missing settings must fail") }
            catch let error as Abort { XCTAssertEqual(error.status, .serviceUnavailable) }
            try await service.seed()
            let initial = try await service.read()
            var prices = initial.amounts
            prices["playerRegistration"] = 575
            let adminID = UUID()
            let updated = try await service.update(.init(version: 1, amounts: prices), by: adminID)
            XCTAssertEqual(updated.fee(.playerRegistration).euros, 5.75)
            XCTAssertEqual(initial.fee(.playerRegistration).euros, 5)
            XCTAssertEqual(updated.history.count, 1)
            XCTAssertEqual(updated.history[0].previousAmounts, initial.amounts)
            XCTAssertEqual(updated.updatedBy, adminID.uuidString)
            try await service.seed()
            let seededAgain = try await service.read()
            XCTAssertEqual(seededAgain.version, 2)
            XCTAssertEqual(seededAgain.amounts, prices)
            do { _ = try await service.update(.init(version: 1, amounts: prices), by: adminID); XCTFail("Stale write accepted") }
            catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
            let request = Request(application: app, on: app.eventLoopGroup.next())
            request.headers.add(name: "X-Fee-Version", value: "1")
            do { _ = try await FeeService.forRequest(request); XCTFail("Stale quote accepted") }
            catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
            request.headers.replaceOrAdd(name: "X-Fee-Version", value: "2")
            _ = try await FeeService.forRequest(request)
            _ = try await mongo[FeeSettings.schema].updateOne(where: ["_id": "global"], to: ["$unset": ["amounts.overdraft": 1]]).get()
            do { _ = try await service.read(); XCTFail("Incomplete settings accepted") }
            catch let error as Abort { XCTAssertEqual(error.status, .serviceUnavailable) }
        }
    }

    func testConcurrentAdminEditsOnlyOneWins() async throws {
        try await withMongo { app, _ in
            let service = FeeService(database: app.db)
            try await service.seed()
            var first = FeeSettings.defaults, second = FeeSettings.defaults
            first["overdraft"] = 6000; second["overdraft"] = 7000
            func attempt(_ values: [String: Int]) async -> Bool {
                do { _ = try await service.update(.init(version: 1, amounts: values), by: UUID()); return true }
                catch { return false }
            }
            async let a = attempt(first)
            async let b = attempt(second)
            let wins = await [a, b].filter { $0 }.count
            XCTAssertEqual(wins, 1)
            let stored = try await service.read()
            XCTAssertEqual(stored.version, 2)
            XCTAssertEqual(stored.history.count, 1)
        }
    }

    func testPostponementRetriesAndInvoiceRecoveryKeepOriginalPrice() async throws {
        try await withMongo { app, _ in
            let service = FeeService(database: app.db)
            try await service.seed()
            let settings = try await service.read()
            let team = Team(id: UUID(), sid: "FEE-TEST", userId: nil, leagueId: nil, leagueCode: nil, points: 0,
                coverimg: "", logo: "", teamName: "Fee Test Team", foundationYear: nil, membershipSince: nil,
                averageAge: "0", coach: nil, captain: nil, trikot: Trikot(home: "", away: ""), balance: 200,
                usremail: "fees@example.com", usrpass: nil, usrtel: nil)
            try await team.create(on: app.db)
            let id = UUID()
            let charge = PostponementFeeService(database: app.db)
            async let a: Void = charge.charge(requestID: id, team: team, fee: settings.fee(.matchPostponement))
            async let b: Void = charge.charge(requestID: id, team: team, fee: settings.fee(.matchPostponement))
            _ = try await (a, b)
            let foundInvoice = try await Rechnung.find(id, on: app.db)
            let invoice = try XCTUnwrap(foundInvoice)
            XCTAssertEqual(invoice.summ, 50)
            XCTAssertEqual(invoice.appliedFee?.version, 1)
            var prices = settings.amounts; prices["matchPostponement"] = 6525
            let changed = try await service.update(.init(version: 1, amounts: prices), by: UUID())
            // Simulate an invoice missing after a partial failure; the durable receipt repairs it.
            try await invoice.delete(on: app.db)
            try await charge.charge(requestID: id, team: team, fee: changed.fee(.matchPostponement))
            let recovered = try await Rechnung.find(id, on: app.db)
            XCTAssertEqual(recovered?.summ, 50)
            XCTAssertEqual(recovered?.appliedFee?.version, 1)
            let savedTeam = try await Team.find(team.requireID(), on: app.db)
            XCTAssertEqual(savedTeam?.balance, 150)
            let count = try await Rechnung.query(on: app.db).count()
            XCTAssertEqual(count, 1)
        }
    }

    func testRegistrationChargeUsesConfiguredCentsAndSnapshotsInvoice() async throws {
        try await withMongo { app, _ in
            let service = FeeService(database: app.db)
            try await service.seed()
            var amounts = FeeSettings.defaults
            amounts["playerRegistration"] = 575
            _ = try await service.update(.init(version: 1, amounts: amounts), by: UUID())
            let team = Team(id: UUID(), sid: "FEE-PLAYER", userId: nil, leagueId: nil, leagueCode: nil, points: 0,
                coverimg: "", logo: "", teamName: "Fee Player Team", foundationYear: nil, membershipSince: nil,
                averageAge: "0", coach: nil, captain: nil, trikot: Trikot(home: "", away: ""), balance: 100,
                usremail: "fees@example.com", usrpass: nil, usrtel: nil)
            try await team.create(on: app.db)
            let player = Player(id: nil, sid: "FEE-PLAYER", image: "", team_oeid: nil, email: "fees@example.com",
                balance: nil, name: "Fee Test", number: "1", birthday: "2000", teamID: team.id,
                nationality: "AT", position: "Feldspieler", eligibility: .Warten, registerDate: "2026-09-15",
                identification: "", status: true, isCaptain: false, bank: false, blockdate: nil)
            let request = Request(application: app, on: app.eventLoopGroup.next())
            try request.content.encode(player)
            _ = try await PlayerController(path: "players").create(req: request).get()
            let storedTeam = try await Team.find(team.requireID(), on: app.db)
            let invoice = try await Rechnung.query(on: app.db).first()
            XCTAssertEqual(storedTeam?.balance, 94.25)
            XCTAssertEqual(invoice?.summ, -5.75)
            XCTAssertEqual(invoice?.appliedFee?.amountMinor, 575)
            XCTAssertEqual(invoice?.appliedFee?.version, 2)
            amounts["playerRegistration"] = 900
            _ = try await service.update(.init(version: 2, amounts: amounts), by: UUID())
            let unchanged = try await Rechnung.query(on: app.db).first()
            XCTAssertEqual(unchanged?.summ, -5.75)
            XCTAssertEqual(unchanged?.appliedFee?.version, 2)
        }
    }

    func testHTTPPermissionsAndPublicProjection() async throws {
        try await withMongo { app, _ in
            try await FeeService(database: app.db).seed()
            let admin = AdminController(path: "admin")
            admin.setupFeeRoutes(on: app.grouped("admin").grouped(Token.authenticator(), User.guardMiddleware(), AdminOnlyMiddleware()))
            AppController(path: "app").setupFeeRoutes(on: app.grouped("app"))
            try app.test(.GET, "/app/fees") { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertFalse(response.body.string.contains("history"))
                XCTAssertFalse(response.body.string.contains("updatedBy"))
            }
            try app.test(.GET, "/admin/fees") { XCTAssertEqual($0.status, .unauthorized) }
            let user = User(id: UUID(), userID: UUID().uuidString, type: .team, firstName: "Fee", lastName: "Test", email: "fees@example.com", passwordHash: "hash")
            try await user.create(on: app.db)
            let token = Token(userId: try user.requireID(), token: "fee-test-token", source: .login, expiresAt: nil)
            try await token.create(on: app.db)
            var headers = HTTPHeaders(); headers.bearerAuthorization = .init(token: token.value)
            try app.test(.PATCH, "/admin/fees", headers: headers) { XCTAssertEqual($0.status, .forbidden) }
            user.type = .admin; try await user.update(on: app.db)
            try app.test(.GET, "/admin/fees", headers: headers) { XCTAssertEqual($0.status, .ok) }
            try app.test(.PATCH, "/admin/fees", headers: headers, beforeRequest: { request in
                try request.content.encode(FeeSettingsUpdate(version: 1, amounts: FeeSettings.defaults))
            }, afterResponse: { XCTAssertEqual($0.status, .ok) })
        }
    }
}
