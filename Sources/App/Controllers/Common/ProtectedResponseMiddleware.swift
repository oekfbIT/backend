import Vapor

/// Prevent authenticated responses containing personal or financial data from
/// being retained by browsers, proxies, or shared caches.
struct ProtectedResponseMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store, private")
        response.headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        return response
    }
}
