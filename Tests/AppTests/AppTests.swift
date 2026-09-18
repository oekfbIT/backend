@testable import App
import XCTVapor

final class AppTests: XCTestCase {
    func testNewRefereesAreActiveByDefault() {
        let referee = Referee(
            name: "Test Referee",
            identification: nil,
            image: nil,
            nationality: "Österreich"
        )

        XCTAssertEqual(referee.active, true)
    }

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

        let id = UUID().uuidString
        let protectedPaths = [
            "admin/sponsors",
            "admin/legal/privacy",
            "teams",
            "players",
            "users",
            "registrations",
            "referees",
            "people-events",
            "sendTestEmail",
            "scraper/league/\(id)",
            "postpone",
            "payments/config",
            "app/player/\(id)",
            "app/team/\(id)",
            "app/account",
            "app/match/\(id)",
            "app/transfer/\(id)",
            "app/referee/me",
            "app/conversation",
            "app/transferSettings/toggle"
        ]

        for path in protectedPaths {
            try app.test(.GET, path, afterResponse: { res in
                XCTAssertEqual(res.status, .unauthorized, "Expected /\(path) to require a bearer token")
            })
        }

        try app.test(.POST, "admin/uploads", afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized, "Expected /admin/uploads to require an administrator bearer token")
        })

        try app.test(.DELETE, "app/match/\(id)/event/\(UUID())", afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized, "Expected referee event deletion to require a bearer token")
        })
    }

    func testRefereeSelfResponseOmitsSensitiveFields() throws {
        let response = AppController.RefereeSelfResponse(
            id: UUID(),
            name: "Referee",
            image: "image.jpg",
            nationality: "AT",
            balance: 12.5,
            assignments: []
        )
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)

        XCTAssertTrue(json.contains("balance"))
        for forbidden in ["identification", "phone", "userId", "email", "password"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }

    func testPublicResponseDTOsDoNotEncodeSensitiveModelFields() throws {
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }

        let userID = UUID()
        let user = User(
            id: userID,
            userID: userID.uuidString,
            type: .team,
            firstName: "Team",
            lastName: "Owner",
            email: "owner@example.com",
            tel: "+431234",
            passwordHash: "SECRET_PASSWORD_HASH"
        )
        let userJSON = try json(user.asPublic())
        XCTAssertFalse(userJSON.contains("passwordHash"))
        XCTAssertFalse(userJSON.contains("SECRET_PASSWORD_HASH"))

        let referee = Referee(
            id: UUID(),
            userId: userID,
            balance: 999,
            name: "Referee",
            identification: "SECRET_ID_DOCUMENT",
            image: "image.jpg",
            nationality: "AT",
            phone: "SECRET_PHONE"
        )
        let refereeJSON = try json(referee.asPublic())
        for forbidden in ["identification", "SECRET_ID_DOCUMENT", "phone", "SECRET_PHONE", "balance"] {
            XCTAssertFalse(refereeJSON.contains(forbidden))
        }

        let trainerJSON = try json(Trainer(
            name: "Trainer",
            email: "SECRET_COACH_EMAIL",
            image: "coach.jpg"
        ).asPublic())
        XCTAssertFalse(trainerJSON.contains("email"))
        XCTAssertFalse(trainerJSON.contains("SECRET_COACH_EMAIL"))

        let player = Player(
            id: UUID(),
            sid: "42",
            image: "player.jpg",
            team_oeid: "private-external-id",
            email: "SECRET_PLAYER_EMAIL",
            balance: 500,
            name: "Player",
            number: "7",
            birthday: "2000-01-01",
            teamID: UUID(),
            nationality: "AT",
            position: "FW",
            eligibility: .Spielberechtigt,
            registerDate: "2020-01-01",
            identification: "SECRET_PLAYER_ID",
            status: true
        )
        let playerJSON = try json(player.asPublic())
        for forbidden in ["email", "SECRET_PLAYER_EMAIL", "identification", "SECRET_PLAYER_ID", "balance"] {
            XCTAssertFalse(playerJSON.contains(forbidden))
        }

        let transferOption = AppController.TransferPlayerOption(
            id: player.id,
            sid: player.sid,
            image: player.image,
            name: player.name,
            number: player.number,
            team: player.$team.id,
            nationality: player.nationality,
            position: player.position,
            eligibility: player.eligibility,
            status: player.status,
            isCaptain: player.isCaptain
        )
        let optionJSON = try json(transferOption)
        for forbidden in ["birthday", "registerDate", "team_oeid", "bank", "email", "identification", "balance"] {
            XCTAssertFalse(optionJSON.contains(forbidden))
        }

        let invoice = Rechnung(
            id: UUID(),
            team: UUID(),
            teamName: "Team",
            number: "INV-1",
            summ: 10,
            topay: 10,
            kennzeichen: "Test"
        )
        invoice.stripeDeposit = StripeDepositDetails(
            topUpId: "SECRET_TOPUP_ID",
            paymentIntentId: "SECRET_PAYMENT_INTENT",
            chargeId: "SECRET_CHARGE_ID",
            amountMinor: 1_000,
            currency: "eur",
            paidAt: Date(),
            balanceAfter: 10,
            livemode: true
        )
        let invoiceJSON = try json(invoice.asPublic())
        for forbidden in ["stripeDeposit", "SECRET_TOPUP_ID", "SECRET_PAYMENT_INTENT", "SECRET_CHARGE_ID"] {
            XCTAssertFalse(invoiceJSON.contains(forbidden))
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
            XCTAssertTrue(body.contains("'/admin/uploads':"))
            XCTAssertTrue(body.contains("'/app/auth/login':"))
            XCTAssertTrue(body.contains("'/app/referee/me':"))
            XCTAssertTrue(body.contains("'/app/match/{matchID}/event/{id}':"))
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

            func pathBlock(_ path: String) -> String {
                let marker = "  '\(path)':"
                guard let start = body.range(of: marker) else { return "" }
                let tail = body[start.lowerBound...]
                let next = tail.dropFirst(marker.count).range(of: "\n  '")
                return next.map { String(tail[..<$0.lowerBound]) } ?? String(tail)
            }

            XCTAssertTrue(pathBlock("/teams").contains("- bearerAuth: []"))
            XCTAssertTrue(pathBlock("/players").contains("- bearerAuth: []"))
            XCTAssertTrue(pathBlock("/app/player/{playerID}").contains("- bearerAuth: []"))
            XCTAssertTrue(pathBlock("/admin/auth/login").contains("- basicAuth: []"))
            XCTAssertTrue(pathBlock("/admin/uploads").contains("- bearerAuth: []"))
            XCTAssertTrue(pathBlock("/app/auth/login").contains("- basicAuth: []"))
            XCTAssertTrue(pathBlock("/app/referee/me").contains("- bearerAuth: []"))
            XCTAssertTrue(pathBlock("/app/match/{matchID}/event/{id}").contains("- bearerAuth: []"))
            XCTAssertFalse(pathBlock("/status").contains("security:"))
            XCTAssertFalse(pathBlock("/client/home/league/{code}").contains("security:"))
            XCTAssertFalse(pathBlock("/webClient/sponsors").contains("security:"))
            XCTAssertFalse(pathBlock("/webClient/news/strafsenat").contains("security:"))
            XCTAssertFalse(pathBlock("/client/homepage/register").contains("security:"))
        })
    }

    func testPublicSponsorDTOOnlyContainsDisplayFields() throws {
        let sponsor = Sponsor(
            id: UUID(),
            name: "Sponsor",
            link: "https://example.com",
            logo: "https://example.com/logo.png",
            footerLogo: "https://example.com/footer.png",
            description: "internal notes",
            type: .sponsor,
            position: 1
        )

        let json = String(decoding: try JSONEncoder().encode(PublicSponsor(sponsor)), as: UTF8.self)
        XCTAssertFalse(json.contains("description"))
        XCTAssertFalse(json.contains("internal notes"))
        XCTAssertFalse(json.contains("created"))
        XCTAssertFalse(json.contains("updated"))
    }

    func testPublicHomepageAccessAllowsOnlyVisibleLeaguesAndHiddenHME() {
        XCTAssertTrue(PublicHomepageAccess.allows(code: "WPL", visibility: true))
        XCTAssertTrue(PublicHomepageAccess.allows(code: "HME", visibility: false))
        XCTAssertFalse(PublicHomepageAccess.allows(code: "NAT", visibility: false))
        XCTAssertFalse(PublicHomepageAccess.allows(code: "MC26", visibility: nil))
    }

    func testPublicHomepageLeagueCanExposeYouTubeWithoutPrivateLeagueFields() throws {
        let overview = PublicLeagueOverview(
            id: UUID(),
            state: .wien,
            code: "HME",
            logo: nil,
            youtube: "https://www.youtube.com/watch?v=public",
            teamcount: 0,
            name: "HOMEPAGE",
            visibility: false
        )

        let json = String(decoding: try JSONEncoder().encode(overview), as: UTF8.self)
        XCTAssertTrue(json.contains("youtube"))
        XCTAssertTrue(json.contains("watch?v=public"))
        for forbidden in ["hourly", "homepageData", "nameLower"] {
            XCTAssertFalse(json.contains(forbidden))
        }
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
