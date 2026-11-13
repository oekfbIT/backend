@testable import App
import XCTVapor

final class LeaderboardHistoryRoutesTests: XCTestCase {
    func testEveryHistoryCategoryHasPublicRouteAndValidatesLeagueID() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try app.register(collection: ClientController(path: "webClient"))
        for category in ["goal", "yellowCard", "redCard", "yellowRedCard"] {
            try app.test(.GET, "webClient/leaderboard/not-a-uuid/\(category)/alltime") { response in
                XCTAssertEqual(response.status, .badRequest, category)
            }
            try app.test(.GET, "webClient/leaderboard/not-a-uuid/\(category)") { response in
                XCTAssertEqual(response.status, .badRequest, category)
            }
        }
    }
}
