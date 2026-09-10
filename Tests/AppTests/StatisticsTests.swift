@testable import App
@testable import FluentMongoDriver
import Fluent
import BSON
import XCTVapor

final class StatisticsTests: XCTestCase {
    private let playerID = UUID(uuidString: "9C3DE3F6-F720-4800-8A80-1736C503924E")!
    private let teamID = UUID(uuidString: "93675315-BC12-4DE5-814A-A9540C301287")!
    private let leagueID = UUID(uuidString: "554ACBEE-A0D3-4E5E-8DCF-50825136C3C8")!

    func testLineupQueriesUseLiteralEmbeddedIDNotMongoRootID() throws {
        // Exercise the actual installed Mongo driver's translation, not just
        // FieldKey.description (which displays both cases as "id").
        for (path, expected) in [
            (PlayerStatisticsService.homePlayerPath, "homeBlanket.players.id"),
            (PlayerStatisticsService.awayPlayerPath, "awayBlanket.players.id")
        ] {
            let field = DatabaseQuery.Field.path(path, schema: Match.schema)
            XCTAssertEqual(try field.makeMongoPath(), expected)
            let filter = DatabaseQuery.Filter.value(field, .subset(inverse: false), .bind([playerID]))
            let document = try filter.makeMongoDBFilter(aggregate: false)
            XCTAssertNotNil(document[expected])
            XCTAssertNil(document[expected.replacingOccurrences(of: ".id", with: "._id")])
            let condition = try XCTUnwrap(document[expected] as? Document)
            let ids = try XCTUnwrap(condition["$in"] as? Document)
            XCTAssertEqual(ids[0] as? String, playerID.uuidString)
        }
        let sheet = try BSONEncoder().encode(overview(playerID))
        XCTAssertEqual(sheet["id"] as? String, playerID.uuidString)
        XCTAssertNil(sheet["_id"])
    }

    func testReportedPlayerHas28RecordedAppearancesNotSevenEventMatches() throws {
        let (matches, events) = try reportedPlayerFixture()
        let snapshot = PlayerStatisticsService.Snapshot(matches: matches, events: events)
        let stats = snapshot.stats(for: playerID, activeLeagueID: leagueID)
        XCTAssertEqual(stats.all.matchesPlayed, 28)
        XCTAssertEqual(stats.all.goalsScored, 7)
        XCTAssertEqual(stats.all.yellowCards, 1)
        XCTAssertEqual(stats.all.redCards, 0)
        XCTAssertEqual(stats.all.yellowRedCrd, 0)
        XCTAssertEqual(stats.all.goalsAverage, 0.25)
        XCTAssertEqual(stats.season.matchesPlayed, 1)
        XCTAssertEqual(stats.season.goalsScored, 0)
        XCTAssertEqual(Set(events.filter { $0.$player.id == playerID }.map { $0.$match.id }).count, 7)
        for (name, expected) in [("2024/2025", 14), ("2025/2026", 13), ("2026/2027", 1)] {
            let season = matches.filter { $0.season?.name == name }
            XCTAssertEqual(PlayerStatisticsService.Snapshot(matches: season, events: events).stats(for: playerID).all.matchesPlayed, expected)
        }
        // Every lineup is visible, including one awarded forfeit, but that
        // unplayed match must not increase appearances.
        XCTAssertEqual(matches.filter { PlayerStatisticsService.contains(playerID, in: $0) }.count, 29)
    }

    func testReportedTeamCardsAndResultsComeFromSameHistoricalMatches() throws {
        let (matches, _) = try reportedPlayerFixture()
        let stats = TeamStatisticsService.aggregate(teamID: teamID, matches: matches)
        XCTAssertEqual(stats.wins, 21)
        XCTAssertEqual(stats.draws, 4)
        XCTAssertEqual(stats.losses, 17)
        XCTAssertEqual(stats.totalScored, 226)
        XCTAssertEqual(stats.totalAgainst, 168)
        XCTAssertEqual(stats.totalPoints, 67)
        XCTAssertEqual(stats.totalYellowCards, 22)
        XCTAssertEqual(stats.totalRedCards, 1)
        XCTAssertEqual(stats.totalYellowRedCards, 0)
    }

    func testHomeAwayEventOnlyDuplicatesOwnGoalsAndSeasonBoundary() throws {
        let home = match(status: .done, home: [playerID])
        let away = match(status: .completed, away: [playerID])
        let eventOnly = match(status: .submitted)
        let future = match(status: .pending, home: [playerID])
        let forfeit = match(status: .cancelled, home: [playerID])
        let unrelated = match(status: .done)
        let oldLeagueID = UUID()
        for m in [home, away, eventOnly, future, forfeit, unrelated] {
            m.$season.value = Season(id: UUID(), leagueId: leagueID, name: "active", details: 1, primary: true)
        }
        away.$season.value = Season(id: UUID(), leagueId: oldLeagueID, name: "other league", details: 1, primary: true)
        let goal = event(in: home, type: .goal)
        let events = [goal, goal, event(in: home, type: .goal, ownGoal: true),
                      event(in: away, type: .yellowCard), event(in: eventOnly, type: .yellowRedCard),
                      event(in: home, type: .redCard), event(in: future, type: .goal),
                      event(in: forfeit, type: .goal),
                      event(in: match(status: .done), type: .goal)] // orphan event
        let snapshot = PlayerStatisticsService.Snapshot(matches: [home, home, away, eventOnly, future, forfeit, unrelated], events: events)
        let stats = snapshot.stats(for: playerID, activeLeagueID: leagueID)
        XCTAssertEqual(stats.all.matchesPlayed, 3)
        XCTAssertEqual(stats.season.matchesPlayed, 2)
        XCTAssertEqual(stats.all.goalsScored, 1)
        XCTAssertEqual(stats.all.yellowCards, 1)
        XCTAssertEqual(stats.season.yellowCards, 0)
        XCTAssertEqual(stats.all.redCards, 1)
        XCTAssertEqual(stats.all.yellowRedCrd, 1)
        XCTAssertEqual(stats.all.goalsAverage!, 1.0 / 3.0, accuracy: 0.00001)
    }

    func testResultPolicyAndHistoricalCardAttribution() throws {
        let played = match(status: .done, home: [playerID])
        played.score = Score(home: 4, away: 2)
        let yellow = event(in: played, type: .yellowCard)
        let red = event(in: played, type: .redCard, assign: .home)
        let yellowRed = event(in: played, type: .yellowRedCard, assign: .home)
        let unknown = event(in: played, type: .redCard)
        unknown.$player.id = UUID()
        played.$events.value = [yellow, yellow, red, yellowRed, unknown]
        XCTAssertEqual(TeamStatisticsService.assignment(for: yellow, in: played), .home)
        XCTAssertNil(TeamStatisticsService.assignment(for: unknown, in: played))
        let forfeit = match(status: .cancelled, home: [playerID])
        forfeit.score = Score(home: 6, away: 0)
        let cancelled = match(status: .cancelled)
        let pending = match(status: .pending)
        let live = match(status: .first)
        XCTAssertTrue(TeamStatisticsService.countsAsResult(forfeit))
        XCTAssertFalse(PlayerStatisticsService.countsAsAppearance(forfeit))
        XCTAssertFalse(TeamStatisticsService.countsAsResult(cancelled))
        XCTAssertFalse(TeamStatisticsService.countsAsResult(live))
        let stats = TeamStatisticsService.aggregate(teamID: teamID, matches: [played, played, forfeit, cancelled, pending, live])
        XCTAssertEqual(stats.wins, 2)
        XCTAssertEqual(stats.draws, 0)
        XCTAssertEqual(stats.totalPoints, 6)
        XCTAssertEqual(stats.totalScored, 10)
        XCTAssertEqual(stats.totalAgainst, 2)
        XCTAssertEqual(stats.totalYellowCards, 1)
        XCTAssertEqual(stats.totalRedCards, 1)
        XCTAssertEqual(stats.totalYellowRedCards, 1)
        let form = TeamStatisticsService.recentForm(teamID: teamID, matches: [played, forfeit, cancelled, pending, live])
        XCTAssertEqual(form.count, 2)
    }

    func testGoalAndCardCorrectionsUseHistoricSheetNotCurrentTeam() {
        let played = match(status: .done, home: [playerID])
        played.homeBlanket?.players[0].yellowCard = 1
        let card = event(in: played, type: .yellowCard)
        TeamStatisticsService.removeCardFromSheet(card, match: played)
        XCTAssertEqual(played.homeBlanket?.players[0].yellowCard, 0)
        TeamStatisticsService.removeCardFromSheet(card, match: played)
        XCTAssertEqual(played.homeBlanket?.players[0].yellowCard, 0)
        let ownGoal = event(in: played, type: .goal, ownGoal: true)
        XCTAssertEqual(TeamStatisticsService.scoringAssignment(for: ownGoal, in: played), .away)
        ownGoal.assign = .away // Explicit assignment already means the scoring side.
        XCTAssertEqual(TeamStatisticsService.scoringAssignment(for: ownGoal, in: played), .away)
    }

    func testDatabaseFailureIsNotReportedAsSuccessfulZeroStatistics() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        let db = FailingStatisticsDatabase(eventLoop: app.eventLoopGroup.next())
        XCTAssertThrowsError(try PlayerStatisticsService.calculate(playerID: playerID, on: db).wait())
        XCTAssertThrowsError(try StatsCacheManager.getPlayerStats(for: [playerID], on: db).wait())
        XCTAssertThrowsError(try StatsCacheManager.getTeamStats(for: teamID, on: db).wait())
        XCTAssertThrowsError(try TeamStatisticsService.table(leagueID: leagueID, primaryOnly: true, on: db).wait())
    }

    func testHistoryContainsEveryRecordedMatchIncludingUnassignedSeasons() throws {
        let (matches, events) = try reportedPlayerFixture()
        let league = League()
        league.id = leagueID
        league.name = "Current league"
        let playerMatches = matches.filter { PlayerStatisticsService.contains(playerID, in: $0) }
        let unassigned = match(status: .done, away: [playerID])
        let groups = ClientController(path: "webClient").seasonGroups(matches: playerMatches + [unassigned], activeSeasons: [], league: league)
        XCTAssertEqual(groups.flatMap(\.matches).count, 30)
        XCTAssertEqual(groups.filter(\.primary).count, 1)
        XCTAssertTrue(groups.contains { $0.seasonName == "Ohne Saisonzuordnung" && $0.matches.count == 1 })
        let countable = groups.flatMap(\.matches).filter { $0.status != .pending && $0.status != .cancelled }.count
        let stats = PlayerStatisticsService.Snapshot(matches: playerMatches + [unassigned], events: events).stats(for: playerID, activeLeagueID: leagueID)
        XCTAssertEqual(countable, stats.all.matchesPlayed)
    }

    func testStandingsIgnoreStaleStoredPointsAndUseSameResultPolicy() {
        let team = Team()
        team.id = teamID
        team.teamName = "Team"
        team.logo = ""
        team.points = 999 // Previously mixed with current-season W/D/L.
        let win = match(status: .completed)
        win.score = Score(home: 2, away: 1)
        let forfeit = match(status: .cancelled)
        forfeit.score = Score(home: 6, away: 0)
        let pending = match(status: .pending)
        let table = TeamStatisticsService.table(teams: [team], matches: [win, forfeit, pending])
        XCTAssertEqual(table.first?.points, 6)
        XCTAssertEqual(table.first?.wins, 2)
        XCTAssertEqual(table.first?.draws, 0)
        XCTAssertEqual(table.first?.scored, 8)
        XCTAssertEqual(table.first?.form.count, 2)
    }

    func testLeaderboardKeepsHistoricalTeamAndExcludesOwnGoals() {
        let played = match(status: .done, home: [playerID])
        let historicTeam = Team()
        historicTeam.id = teamID
        historicTeam.teamName = "Historic team"
        historicTeam.logo = "historic-logo"
        played.$homeTeam.value = historicTeam
        let goal = event(in: played, type: .goal)
        goal.name = "Historic name"
        let ownGoal = event(in: played, type: .goal, ownGoal: true)
        // No live player record: historic goals must survive transfers/deletion.
        let entries = LeaderboardService.map([goal, goal, ownGoal], matchByID: [played.id!: played], playerByID: [:])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.count, 1)
        XCTAssertEqual(entries.first?.teamId, teamID.uuidString)
        XCTAssertEqual(entries.first?.teamName, "Historic team")
    }

    private func overview(_ id: UUID) -> PlayerOverview {
        PlayerOverview(id: id, sid: "test", name: "Player", number: 1)
    }

    private func match(status: GameStatus, home: [UUID] = [], away: [UUID] = []) -> Match {
        let match = Match(id: UUID(), details: MatchDetails(gameday: 1), homeTeamId: teamID, awayTeamId: UUID(),
                         homeBlanket: Blankett(name: "Home", dress: nil, logo: nil, players: home.map(overview)),
                         awayBlanket: Blankett(name: "Away", dress: nil, logo: nil, players: away.map(overview)),
                         score: Score(home: 0, away: 0), status: status)
        match.$events.value = []
        return match
    }

    private func event(in match: Match, type: MatchEventType, assign: MatchAssignment? = nil, ownGoal: Bool? = nil) -> MatchEvent {
        MatchEvent(id: UUID(), matchId: match.id!, type: type, playerId: playerID, minute: 1,
                   name: nil, image: nil, number: nil, assign: assign, ownGoal: ownGoal)
    }

    private struct Fixture: Decodable {
        let id: UUID, seasonID: UUID, primary: Bool, seasonName: String, status: GameStatus
        let homeID: UUID, awayID: UUID, score: Score, homePlayers: [UUID], awayPlayers: [UUID]
        let events: [Event]
        struct Event: Decodable {
            let id: UUID, playerID: UUID?, type: MatchEventType, assign: MatchAssignment?, ownGoal: Bool?
        }
    }

    private func reportedPlayerFixture() throws -> ([Match], [MatchEvent]) {
        // Minimized from public match-detail responses on 2026-09-10. No images,
        // names, contact data or unrelated goals are retained in this fixture.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "player-17007-history", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        var events = [MatchEvent]()
        let matches = rows.map { row -> Match in
            let match = Match(id: row.id, details: MatchDetails(gameday: 1), homeTeamId: row.homeID, awayTeamId: row.awayID,
                              homeBlanket: Blankett(name: nil, dress: nil, logo: nil, players: row.homePlayers.map(overview)),
                              awayBlanket: Blankett(name: nil, dress: nil, logo: nil, players: row.awayPlayers.map(overview)), score: row.score, status: row.status)
            match.$season.value = Season(id: row.seasonID, leagueId: leagueID, name: row.seasonName, details: 1, primary: row.primary)
            let matchEvents = row.events.map { e in
                MatchEvent(id: e.id, matchId: row.id, type: e.type, playerId: e.playerID, minute: 1,
                           name: nil, image: nil, number: nil, assign: e.assign, ownGoal: e.ownGoal)
            }
            match.$events.value = matchEvents
            events += matchEvents
            return match
        }
        return (matches, events)
    }
}

private final class FailingStatisticsDatabase: Database {
    struct Configuration: DatabaseConfiguration {
        var middleware: [AnyModelMiddleware] = []
        func makeDriver(for databases: Databases) -> DatabaseDriver { fatalError("Not used") }
    }
    let context: DatabaseContext
    var inTransaction: Bool { false }
    init(eventLoop: EventLoop) {
        context = DatabaseContext(configuration: Configuration(), logger: Logger(label: "stats-test"), eventLoop: eventLoop)
    }
    func execute(query: DatabaseQuery, onOutput: @escaping (DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(Abort(.serviceUnavailable, reason: "Simulated database timeout"))
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { eventLoop.makeSucceededFuture(()) }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { eventLoop.makeSucceededFuture(()) }
    func transaction<T>(_ closure: @escaping (Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
    func withConnection<T>(_ closure: @escaping (Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
}
