@testable import App
import XCTVapor

final class AchievementTests: XCTestCase {
    func testLabelsAndOptionalImages() throws {
        let result = try AchievementInput(label: "  Saisonmeister 2025/26  ", imageUrl: "  ").normalized()
        XCTAssertEqual(result.0, "Saisonmeister 2025/26")
        XCTAssertNil(result.1)
        XCTAssertNil(try AchievementInput(label: "Winner", imageUrl: nil).normalized().1)
        XCTAssertThrowsError(try AchievementInput(label: " \n ", imageUrl: nil).normalized())
        XCTAssertThrowsError(try AchievementInput(label: String(repeating: "a", count: 201), imageUrl: nil).normalized())
        for url in ["javascript:alert(1)", "data:image/png;base64,abc", "/relative.png", "https://"] {
            XCTAssertThrowsError(try AchievementInput(label: "Winner", imageUrl: url).normalized())
        }
        XCTAssertEqual(try AchievementInput(label: "Winner", imageUrl: " https://example.com/trophy.png ").normalized().1, "https://example.com/trophy.png")
    }
    func testAdminRoutesRequireAuthentication() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try app.register(collection: AdminController(path: "admin"))
        for owner in ["team", "player"] {
            let path = "admin/achievements/\(owner)/\(UUID())"
            for (method, endpoint) in [(HTTPMethod.GET, path), (.POST, path), (.PUT, path + "/\(UUID())"), (.DELETE, path + "/\(UUID())")] {
                try app.test(method, endpoint, afterResponse: { response in
                    XCTAssertEqual(response.status, .unauthorized)
                })
            }
        }
    }
}
