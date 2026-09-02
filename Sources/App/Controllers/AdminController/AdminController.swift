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
        // Login is the only public route in the admin namespace.
        setupAuthRoutes(on: route)

        let authed = route.grouped(
            Token.authenticator(),
            User.guardMiddleware()
        )

        let admin = authed.grouped(AdminOnlyMiddleware())
        // MARK: - AUTH ROUTES
//        try setupAuthRoutes(on: route)
        setupLeagueRoutes(on: admin)
        setupTeamRoutes(on: admin)
        setupSeasonRoutes(on: admin)
        setupMatchRoutes(on: admin)
        setupPlayerRoutes(on: admin)
        setupRefereeRoutes(on: admin)
        setupNewsRoutes(on: admin)
        setupStadiumRoutes(on: admin)
        setupUserRoutes(on: admin)
        setupRegistrationRoutes(on: admin)
        setupLegalReadRoutes(on: admin)
        setupLegalWriteRoutes(on: admin)
        setupSponsorRoutes(on: admin)
        setupSearchRoutes(on: admin)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}
