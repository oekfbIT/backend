@testable import App
import XCTVapor

final class AppTests: XCTestCase {
    func testCreatedTokensAreCookieAndBearerSafe() throws {
        let id = UUID()
        let user = User(
            id: id,
            userID: id.uuidString,
            type: .admin,
            firstName: "Admin",
            lastName: "User",
            email: "admin@example.com",
            passwordHash: "unused"
        )

        let token = try user.createToken(source: .login)

        XCTAssertEqual(token.$user.id, id)
        XCTAssertFalse(token.value.isEmpty)
        XCTAssertNil(token.value.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
        XCTAssertFalse(token.value.contains("="))
        XCTAssertTrue(token.isValid)
    }

    func testAdminRoutesRequireAuthentication() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try routes(app)

        for path in ["admin/sponsors", "admin/legal/privacy"] {
            try app.test(.GET, path, afterResponse: { res in
                XCTAssertEqual(res.status, .unauthorized, "Expected /\(path) to require an admin bearer token")
            })
        }
    }

    func testOpenAPIDocumentIncludesRegisteredRoutes() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try routes(app)
        OpenAPISupport.registerRoutes(on: app)

        try app.test(.GET, "openapi.yaml", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)

            let body = res.body.string
            XCTAssertTrue(body.contains("openapi: 3.1.0"))
            XCTAssertTrue(body.contains("title: OEKFB Backend API"))
            XCTAssertTrue(body.contains("'/status':"))
            XCTAssertTrue(body.contains("'/admin/auth/login':"))
            XCTAssertTrue(body.contains("'/app/auth/login':"))
            XCTAssertTrue(body.contains("'/app/player/{playerID}':"))
            XCTAssertTrue(body.contains("'/app/player/{playerID}/email':"))
            XCTAssertTrue(body.contains("'/app/leaderboard/league/{id}/primary/goals':"))
            XCTAssertTrue(body.contains("'/events/player/{playerId}':"))
            XCTAssertTrue(body.contains("'/people-events/{id}/guests/{guestID}':"))
            XCTAssertTrue(body.contains("name: 'Admin / Auth'"))
            XCTAssertTrue(body.contains("name: 'Mobile App / Auth'"))
            XCTAssertTrue(body.contains("name: 'Guest List'"))
            XCTAssertTrue(body.contains("bearerAuth:"))
            XCTAssertTrue(body.contains("basicAuth:"))
        })
    }

    func testSwaggerDocsAreServed() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        OpenAPISupport.registerRoutes(on: app)

        try app.test(.GET, "docs", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("SwaggerUIBundle"))
            XCTAssertTrue(res.body.string.contains("/openapi.yaml"))
        })
    }

    func testPlayerAppearanceRulesUseTeamSheetsAndPlayedStatuses() throws {
        let playerID = UUID()
        let homeTeamID = UUID()
        let awayTeamID = UUID()
        let player = PlayerOverview(
            id: playerID,
            sid: "123",
            name: "Test Player",
            number: 7,
            image: nil,
            yellowCard: 0,
            redYellowCard: 0,
            redCard: 0
        )
        let match = Match(
            details: MatchDetails(gameday: 1, date: nil, stadium: nil, location: nil),
            homeTeamId: homeTeamID,
            awayTeamId: awayTeamID,
            homeBlanket: Blankett(name: "Home", dress: nil, logo: nil, players: [player]),
            awayBlanket: nil,
            score: Score(home: 0, away: 0),
            status: .pending
        )

        XCTAssertTrue(PlayerStatisticsService.contains(playerID, in: match))
        XCTAssertFalse(PlayerStatisticsService.countsAsAppearance(match))

        match.status = .first
        XCTAssertTrue(PlayerStatisticsService.countsAsAppearance(match))

        match.status = .cancelled
        XCTAssertFalse(PlayerStatisticsService.countsAsAppearance(match))

        match.status = .done
        XCTAssertTrue(PlayerStatisticsService.countsAsAppearance(match))
    }
}
