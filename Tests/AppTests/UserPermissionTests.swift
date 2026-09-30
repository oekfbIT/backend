import XCTest
@testable import App

final class UserPermissionTests: XCTestCase {
    private func user(type: UserType, permissions: [UserPermission]?) -> User {
        let user = User(userID: "test", type: type, firstName: "Test", lastName: "User",
                        email: "test@example.com", passwordHash: "hash")
        user.permissions = permissions
        return user
    }

    func testAdminCanHaveNoPermissions() {
        let admin = user(type: .admin, permissions: [])
        XCTAssertFalse(admin.hasPermission(.usersRead))
    }

    func testAdminCanHaveEveryPermission() {
        let admin = user(type: .admin, permissions: UserPermission.allCases)
        XCTAssertTrue(UserPermission.allCases.allSatisfy(admin.hasPermission))
    }

    func testNonAdminCannotUseAdminPermission() {
        let team = user(type: .team, permissions: [.usersDelete])
        XCTAssertFalse(team.hasPermission(.usersDelete))
    }

    func testLegacyAdminRemainsFullyEnabled() {
        let admin = user(type: .admin, permissions: nil)
        XCTAssertEqual(admin.effectivePermissions, Set(UserPermission.allCases))
    }
}
