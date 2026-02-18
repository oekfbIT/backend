import Vapor

struct AdminOnlyMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let user = try req.auth.require(User.self)

        guard user.type == .admin else {
            throw Abort(.forbidden, reason: "Admin access required.")
        }

        return try await next.respond(to: req)
    }
}
