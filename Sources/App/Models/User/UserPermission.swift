import Vapor

/// Fine-grained capabilities for users of the administration API.
///
/// Raw values are part of the public API and are stored in MongoDB. Add new
/// cases instead of renaming existing ones.
enum UserPermission: String, Codable, CaseIterable, Hashable, Content {
    case usersRead = "users.read"
    case usersCreate = "users.create"
    case usersUpdate = "users.update"
    case usersDelete = "users.delete"

    case playersRead = "players.read"
    case playersCreate = "players.create"
    case playersUpdate = "players.update"
    case playersDelete = "players.delete"

    case teamsRead = "teams.read"
    case teamsCreate = "teams.create"
    case teamsUpdate = "teams.update"
    case teamsDelete = "teams.delete"

    case financesRead = "finances.read"
    case financesManage = "finances.manage"
    case ordersRead = "orders.read"
    case ordersManage = "orders.manage"

    case competitionsManage = "competitions.manage"
    case refereesManage = "referees.manage"
    case disciplineManage = "discipline.manage"
    case transfersManage = "transfers.manage"
    case contentManage = "content.manage"
    case communicationsManage = "communications.manage"
    case analyticsRead = "analytics.read"
    case eventsManage = "events.manage"
}

extension User {
    /// `nil` only occurs for records created before permissions were added.
    /// Keeping legacy admins fully enabled avoids locking the installation on
    /// first deployment; the migration persists this value immediately.
    var effectivePermissions: Set<UserPermission> {
        if let permissions { return Set(permissions) }
        return type == .admin ? Set(UserPermission.allCases) : []
    }

    func hasPermission(_ permission: UserPermission) -> Bool {
        type == .admin && effectivePermissions.contains(permission)
    }

}
