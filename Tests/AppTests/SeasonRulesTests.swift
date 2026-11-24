@testable import App
import Fluent
import FluentMongoDriver
import XCTVapor

final class SeasonRulesTests: XCTestCase {
    func testFourConsecutiveAppearancesTriggerSuspension() {
        XCTAssertTrue(YellowCardSuspension.triggersSuspension(previousAppearances: [true, true, true]))
        XCTAssertFalse(YellowCardSuspension.triggersSuspension(previousAppearances: [true, false, true, true]))
        XCTAssertFalse(YellowCardSuspension.triggersSuspension(previousAppearances: [true, true]))
        XCTAssertFalse(YellowCardSuspension.triggersSuspension(previousAppearances: []))
    }

    func testTransferReservationIsIndependentForEachSeasonAndPlayer() {
        let seasonID = UUID()
        let playerID = UUID()
        let key = SeasonTransferReservation.key(seasonID: seasonID, playerID: playerID)
        XCTAssertEqual(key, SeasonTransferReservation.key(seasonID: seasonID, playerID: playerID))
        XCTAssertNotEqual(key, SeasonTransferReservation.key(seasonID: UUID(), playerID: playerID))
        XCTAssertNotEqual(key, SeasonTransferReservation.key(seasonID: seasonID, playerID: UUID()))
    }

    func testMongoTransferAndSuspensionLifecycleAcrossSeasons() async throws {
        guard let port = Environment.get("SEASON_TEST_MONGO_PORT"), UInt16(port) != nil else {
            throw XCTSkip("Set SEASON_TEST_MONGO_PORT to an isolated local MongoDB replica set.")
        }
        let app = Application(.testing)
        let name = "oekfb_season_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try app.databases.use(.mongo(connectionString: "mongodb://127.0.0.1:\(port)/\(name)"), as: .mongo)
        defer { try? (app.db as? MongoDatabaseRepresentable)?.raw.drop().wait(); app.shutdown() }

        let req = Request(application: app, on: app.eventLoopGroup.next())
        req.auth.login(User(id: UUID(), userID: "Admin", type: .admin, firstName: "Test",
                            lastName: "Admin", email: "test@example.com", passwordHash: "hash"))
        let league = UUID()
        let origin = makeTeam(leagueID: league, name: "Origin")
        let target = makeTeam(leagueID: league, name: "Target")
        try await origin.create(on: app.db)
        try await target.create(on: app.db)
        let originID = try origin.requireID()
        let targetID = try target.requireID()
        let player = Player(sid: "TEST", image: nil, team_oeid: nil, email: "player@example.com",
                            name: "Test Player", number: "1", birthday: "", teamID: originID,
                            nationality: "", position: "", eligibility: .Spielberechtigt, registerDate: "",
                            identification: nil, status: true)
        player.transferred = true
        try await player.create(on: app.db)
        let playerID = try player.requireID()
        let first = Season(leagueId: league, name: "First", details: 1, primary: true)
        let second = Season(leagueId: league, name: "Second", details: 1, primary: false)
        try await first.create(on: app.db)
        try await second.create(on: app.db)
        try await SeasonTransferRulesMigration().prepare(on: app.db)

        try await SeasonTransfers.setOpen(true, on: app.db)
        let anotherLeague = UUID()
        let closedTeam = makeTeam(leagueID: anotherLeague, name: "Closed league")
        let closedSeason = Season(leagueId: anotherLeague, name: "Closed", details: 1, primary: true)
        try await closedTeam.create(on: app.db)
        try await closedSeason.create(on: app.db)
        let controller = AppController(path: "app")
        req.parameters.set("teamID", to: try target.requireID().uuidString)
        let targetIsOpen = try await controller.isTeamTransferWindowOpen(req: req)
        XCTAssertTrue(targetIsOpen)
        req.parameters.set("teamID", to: try closedTeam.requireID().uuidString)
        let otherIsOpen = try await controller.isTeamTransferWindowOpen(req: req)
        XCTAssertFalse(otherIsOpen)

        let secondBefore = try await Season.find(second.id, on: app.db)
        XCTAssertNil(secondBefore?.transferOpen)
        let outcomes = await withTaskGroup(of: Transfer?.self, returning: [Transfer].self) { group in
            for _ in 0..<2 {
                group.addTask { try? await SeasonTransfers.create(playerID: playerID, targetID: targetID, req: req) }
            }
            var created: [Transfer] = []
            for await outcome in group {
                if let outcome { created.append(outcome) }
            }
            return created
        }
        XCTAssertEqual(outcomes.count, 1)
        let pending = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(pending.seasonID, first.id)
        let requester = User(id: UUID(), userID: "Team", type: .team, firstName: "Test",
                             lastName: "Team", email: "team@example.com", passwordHash: "hash")
        req.auth.login(requester)
        do {
            try await SeasonTransfers.withdraw(id: pending.requireID(), req: req)
            XCTFail("Only the requesting team can withdraw this transfer.")
        } catch let error as Abort {
            XCTAssertEqual(error.status, .forbidden)
        }

        target.$user.id = requester.id
        try await target.update(on: app.db)
        try await SeasonTransfers.withdraw(id: pending.requireID(), req: req)
        let withdrawn = try await Transfer.find(pending.id, on: app.db)
        XCTAssertEqual(withdrawn?.withdrawn, true)
        XCTAssertEqual(withdrawn?.status, .abgelehnt)

        let retry = try await SeasonTransfers.create(playerID: playerID, targetID: targetID, req: req)
        _ = try await SeasonTransfers.respond(id: retry.requireID(), accept: true, req: req, fromEmail: true)
        req.parameters.set("teamID", to: try target.requireID().uuidString)
        let history = try await controller.getTeamTransferHistory(req: req)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.seasonName == first.name })

        let used = try await SeasonTransfers.options(for: origin, on: app.db)
        XCTAssertTrue(used.isEmpty)
        let moved = try await Player.find(playerID, on: app.db)
        XCTAssertEqual(moved?.$team.id, targetID)

        let lineup = Blankett(name: "Target", dress: nil, logo: nil, players: [
            PlayerOverview(id: playerID, sid: player.sid, name: player.name, number: 1)
        ])
        let now = Date()
        for day in 1...4 {
            let game = Match(details: MatchDetails(gameday: day, date: now.addingTimeInterval(Double(day - 4) * 86_400)),
                             homeTeamId: targetID, awayTeamId: originID, homeBlanket: lineup, awayBlanket: nil,
                             score: Score(home: 0, away: 0), status: .completed, seasonId: first.id)
            try await game.create(on: app.db)
            let card = CardRequest(playerId: playerID, teamId: targetID, minute: 10, name: nil, image: nil, number: nil)
            _ = try await YellowCardSuspension.record(matchID: game.requireID(), card: card, req: req)
            let updated = try await Player.find(playerID, on: app.db)
            XCTAssertEqual(updated?.eligibility, day == 4 ? .Gesperrt : .Spielberechtigt)
        }

        let suspended = try await Player.find(playerID, on: app.db)
        XCTAssertEqual(suspended?.yellowCardSuspensionSeasonID, first.id)
        let upcoming = Match(details: MatchDetails(gameday: 5, date: now), homeTeamId: targetID,
                             awayTeamId: originID, homeBlanket: lineup, awayBlanket: nil,
                             score: Score(home: 0, away: 0), status: .pending, seasonId: first.id)
        do {
            try await YellowCardSuspension.validateLineup(for: upcoming, on: app.db)
            XCTFail("Expected an active suspension to block this lineup.")
        } catch let error as Abort {
            XCTAssertEqual(error.status, .forbidden)
        }
        upcoming.$season.id = second.id
        try await YellowCardSuspension.validateLineup(for: upcoming, on: app.db)

        first.primary = false
        second.primary = true
        try await first.update(on: app.db)
        try await second.update(on: app.db)
        let newlyOpen = try await SeasonTransfers.isOpen(on: app.db)
        XCTAssertFalse(newlyOpen)
        try await SeasonTransfers.setOpen(true, on: app.db)
        let eligible = try await SeasonTransfers.options(for: origin, on: app.db)
        XCTAssertEqual(eligible.compactMap(\.id), [playerID])
        origin.$user.id = requester.id
        try await origin.update(on: app.db)
        let next = try await SeasonTransfers.create(playerID: playerID, targetID: originID, req: req)
        XCTAssertEqual(next.seasonID, second.id)
    }

    private func makeTeam(leagueID: UUID, name: String) -> Team {
        Team(sid: name, userId: nil, leagueId: leagueID, leagueCode: nil, points: 0,
             coverimg: "", logo: "", teamName: name, foundationYear: nil, membershipSince: nil,
             averageAge: nil, coach: nil, trikot: Trikot(home: "", away: ""),
             usremail: nil, usrpass: nil, usrtel: nil)
    }

}
