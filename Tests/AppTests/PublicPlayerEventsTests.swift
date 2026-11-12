@testable import App
import XCTVapor

final class PublicPlayerEventsTests: XCTestCase {
    func testPublicPlayerDetailIncludesGoalsAndEveryCardWithMatchHeadline() throws {
        let playerID = UUID(), matchID = UUID()
        let player = PublicPlayer(id: playerID, sid: "123", image: nil, name: "Player", number: "7",
            team: nil, nationality: "AT", position: "", eligibility: .Warten, status: true,
            isCaptain: false, allstats: nil, seasonstats: nil)
        let headline = AppModels.Matchheadline(homeID: UUID(), homeName: "Home", homeLogo: "home.png",
            gameday: 3, date: Date(timeIntervalSince1970: 0), awayID: UUID(), awayName: "Away", awayLogo: "away.png")
        let wrapper = AppModels.AppPlayerMatchEventWrapper(id: playerID, sid: "123", name: "Player",
            number: "7", nationality: "AT", eligilibity: .Warten, image: "")
        let types: [MatchEventType] = [.goal, .yellowCard, .redCard, .yellowRedCard]
        let events = types.enumerated().map { index, type in
            AppModels.AppMatchEvent(id: UUID(), headline: headline, type: type, player: wrapper,
                minute: index + 1, matchID: matchID, name: "Player", image: nil, number: "7", assign: .home, ownGoal: false)
        }
        let response = PlayerDetailResponse(player: player, upcoming: [], news: nil, events: events)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(response)) as? [String: Any])
        let encodedEvents = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(encodedEvents.compactMap { $0["type"] as? String }, types.map(\.rawValue))
        XCTAssertEqual(encodedEvents.first?["match_id"] as? String, matchID.uuidString)
        let encodedHeadline = try XCTUnwrap(encodedEvents.first?["headline"] as? [String: Any])
        XCTAssertEqual(encodedHeadline["home_name"] as? String, "Home")
        XCTAssertEqual(encodedHeadline["gameday"] as? Int, 3)
    }
}
