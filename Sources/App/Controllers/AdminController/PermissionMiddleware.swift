import Vapor

struct PermissionMiddleware: AsyncMiddleware {
    let required: Set<UserPermission>

    init(_ required: UserPermission) {
        self.required = [required]
    }

    init(anyOf required: [UserPermission]) {
        self.required = Set(required)
    }

    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let user = try req.auth.require(User.self)
        guard required.contains(where: user.hasPermission) else {
            let names = required.map(\.rawValue).sorted().joined(separator: ", ")
            throw Abort(.forbidden, reason: "One of these permissions is required: \(names)")
        }
        return try await next.respond(to: req)
    }
}
