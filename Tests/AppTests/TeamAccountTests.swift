@testable import App
import XCTVapor

final class TeamAccountTests: XCTestCase {
    func testAccountDTOExcludesCredentials() throws {
        let user = User(id: UUID(), userID: "owner-42", type: .team,
                        firstName: "Team", lastName: "Owner", verified: true,
                        email: "owner@example.com", tel: "123", passwordHash: "secret-hash")
        let data = try JSONEncoder().encode(AdminController.TeamAccountUser(user))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "userID", "firstName", "lastName", "email", "tel", "verified", "type"]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-hash"))
    }

    func testPasswordLengthAndHashVerification() throws {
        let passwords = (0..<100).map { _ in AdminController.generateTeamAccountPassword() }
        XCTAssertEqual(Set(passwords).count, passwords.count)
        for password in passwords {
            XCTAssertEqual(password.count, 10)
            XCTAssertNil(password.range(of: "[^A-Za-z0-9]", options: .regularExpression))
        }
        let hash = try Bcrypt.hash(passwords[0])
        XCTAssertTrue(try Bcrypt.verify(passwords[0], created: hash))
        XCTAssertFalse(try Bcrypt.verify("wrong-password", created: hash))
    }

    func testSearchIsLiteralAndCaseInsensitive() throws {
        let pattern = AdminController.teamAccountSearchPattern("Owner+test@example.com")
        let regex = try NSRegularExpression(pattern: ".*\(pattern).*")
        let exact = "OWNER+TEST@EXAMPLE.COM"
        XCTAssertNotNil(regex.firstMatch(in: exact, range: NSRange(exact.startIndex..., in: exact)))
        let other = "OwnerXXXXXXXXtest@exampleXcom"
        XCTAssertNil(regex.firstMatch(in: other, range: NSRange(other.startIndex..., in: other)))
    }

    func testAccountRoutesRequireAuthentication() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try routes(app)
        let id = UUID().uuidString
        let endpoints: [(HTTPMethod, String)] = [
            (.GET, "admin/users/selection"),
            (.GET, "admin/teams/\(id)/user"),
            (.PUT, "admin/teams/\(id)/user"),
            (.POST, "admin/teams/\(id)/user/reset-password")
        ]
        for (method, path) in endpoints {
            try app.test(method, path, afterResponse: { response in
                XCTAssertEqual(response.status, .unauthorized)
            })
        }
    }
}
