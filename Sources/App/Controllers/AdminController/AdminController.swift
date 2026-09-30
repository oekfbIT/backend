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
            User.guardMiddleware(),
            ProtectedResponseMiddleware()
        )

        let admin = authed.grouped(AdminOnlyMiddleware())
        // MARK: - AUTH ROUTES
//        try setupAuthRoutes(on: route)
        let competitions = admin.grouped(PermissionMiddleware(.competitionsManage))
        let teams = admin.grouped(PermissionMiddleware(anyOf: [.teamsRead, .teamsCreate, .teamsUpdate, .teamsDelete]))
        let content = admin.grouped(PermissionMiddleware(.contentManage))

        setupLeagueRoutes(on: competitions)
        setupTeamRoutes(on: teams)
        setupTeamAccountRoutes(on: teams)
        setupSeasonRoutes(on: competitions)
        setupMatchRoutes(on: competitions)
        setupPlayerRoutes(on: admin)
        setupRefereeRoutes(on: admin.grouped(PermissionMiddleware(.refereesManage)))
        setupNewsRoutes(on: content)
        setupStadiumRoutes(on: competitions)
        setupUserRoutes(on: admin)
        setupRegistrationRoutes(on: admin)
        setupLegalReadRoutes(on: content)
        setupLegalWriteRoutes(on: content)
        setupSponsorRoutes(on: content)
        setupAchievementRoutes(on: content)
        setupSearchRoutes(on: admin)
        setupAnalyticsRoutes(on: admin.grouped(PermissionMiddleware(.analyticsRead)))
        setupPushDeviceRoutes(on: admin.grouped(PermissionMiddleware(.communicationsManage)))
        setupFeeRoutes(on: admin)
        setupUploadRoutes(on: content)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}
