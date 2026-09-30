import Fluent

struct UserPermissionsMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field(User.FieldKeys.permissions, .array(of: .string))
            .update()

        let users = try await User.query(on: database).all()
        for user in users where user.permissions == nil {
            user.permissions = user.type == .admin ? UserPermission.allCases : []
            try await user.update(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField(User.FieldKeys.permissions)
            .update()
    }
}
