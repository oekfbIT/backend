import Vapor
import Fluent
import Foundation

// MARK: - Main Controller
final class AdminController: RouteCollection {

    let path: String
    
    init(path: String) {
        self.path = path
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: path))
        // Public admin auth (no Token.authenticator() here)
        setupAuthRoutes(on: route)

        let authed = route.grouped(
            Token.authenticator(),
            User.guardMiddleware()
        )

        let admin = authed.grouped(AdminOnlyMiddleware())
        // MARK: - AUTH ROUTES
//        try setupAuthRoutes(on: route)
        try setupLeagueRoutes(on: admin)
        try setupTeamRoutes(on: admin)
        try setupSeasonRoutes(on: admin)
        try setupMatchRoutes(on: admin) 
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}
