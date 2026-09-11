@testable import App
import XCTVapor

final class ShortNameTests: XCTestCase {
    private func team(_ shortName: String?) -> Team {
        let team = Team()
        team.id = UUID()
        team.teamName = "Bida United"
        team.logo = "logo.png"
        team.shortName = shortName
        return team
    }

    func testStandingsEncodeCurrentShortName() throws {
        let team = team("BDU")
        let row = try XCTUnwrap(TeamStatisticsService.table(teams: [team], matches: []).first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(object["shortName"] as? String, "BDU")
        XCTAssertEqual(object["name"] as? String, "Bida United")
    }

    func testFixtureUsesCurrentTeamShortNameAndSupportsClearing() throws {
        let home = team("BDU")
        let away = team(nil)
        let match = Match()
        match.id = UUID()
        match.details = MatchDetails(gameday: 1)
        match.$homeTeam.id = home.id!
        match.$homeTeam.value = home
        match.$awayTeam.id = away.id!
        match.$awayTeam.value = away
        match.homeBlanket = Blankett(name: home.teamName, dress: nil, logo: home.logo, players: [])
        match.awayBlanket = Blankett(name: away.teamName, dress: nil, logo: away.logo, players: [])
        match.score = Score(home: 0, away: 0)
        match.status = .pending
        let client = ClientController(path: "webClient")
        let output = try XCTUnwrap(client.mapMatchesToShort([match]).first)
        XCTAssertEqual(output.homeBlanket?.shortName, "BDU")
        XCTAssertNil(output.awayBlanket?.shortName)
        let season = ClientSeasonMatches(id: UUID(), name: "2026/2027", primary: true, matches: [output])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try encoder.encode(season), as: UTF8.self)
        XCTAssertTrue(json.contains("home_blanket"))
        XCTAssertTrue(json.contains("BDU"))
        XCTAssertTrue(json.contains("short_name"))
        home.shortName = nil
        XCTAssertNil(client.mapMatchesToShort([match]).first?.homeBlanket?.shortName)
    }

    func testSeasonGroupsHandleUnloadedTeamParentsAndUseLoadedShortNames() throws {
        let match = Match()
        match.id = UUID()
        match.details = MatchDetails(gameday: 1)
        match.$homeTeam.id = UUID()
        match.$awayTeam.id = UUID()
        match.$season.id = nil
        match.homeBlanket = Blankett(name: "Bida United", dress: nil, logo: nil, players: [])
        match.awayBlanket = Blankett(name: "Opponent", dress: nil, logo: nil, players: [])
        match.score = Score(home: 0, away: 0)
        match.status = .pending
        let client = ClientController(path: "webClient")

        // The team/player history path previously trapped in Match.homeTeam.getter.
        let unloaded = try XCTUnwrap(client.seasonGroups(matches: [match], activeSeasons: [], league: nil).first?.matches.first)
        XCTAssertEqual(unloaded.homeBlanket?.name, "Bida United")
        XCTAssertEqual(unloaded.awayBlanket?.name, "Opponent")
        XCTAssertNil(unloaded.homeBlanket?.shortName)

        match.$homeTeam.value = team("BDU")
        match.$awayTeam.value = team("OPP")
        let loaded = try XCTUnwrap(client.seasonGroups(matches: [match], activeSeasons: [], league: nil).first?.matches.first)
        XCTAssertEqual(loaded.homeBlanket?.shortName, "BDU")
        XCTAssertEqual(loaded.awayBlanket?.shortName, "OPP")
    }

    func testMatchDetailOverridesStaleShortNameWithoutChangingLineup() {
        let team = team("BDU")
        var stored = Blankett(name: "Bida United", dress: "shirt.png", logo: "logo.png", players: [])
        stored.shortName = "OLD"
        let client = ClientController(path: "webClient")
        let result = client.publicBlanket(stored, team: team)
        XCTAssertEqual(result.shortName, "BDU")
        XCTAssertEqual(result.dress, "shirt.png")
        XCTAssertEqual(stored.shortName, "OLD")
        team.shortName = nil
        XCTAssertNil(client.publicBlanket(stored, team: team).shortName)
    }
}
