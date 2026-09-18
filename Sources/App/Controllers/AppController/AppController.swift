import Vapor
import Fluent
import Foundation

// MARK: - Async helper
extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}

// MARK: - Main Controller
final class AppController: RouteCollection {

    let path: String
    
    init(path: String) {
        self.path = path
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: path))

        // Login and the first account-verification step are the only anonymous
        // routes in the application namespace.
        try setupAuthRoutes(on: route)
        setupPublicTeamRegistrationRoutes(on: route)

        let authenticated = route.grouped(
            Token.authenticator(),
            User.guardMiddleware(),
            ProtectedResponseMiddleware()
        )

        // MARK: - SEARCH ROUTES
        try setupSearchRoutes(on: authenticated)
        try setupChatRoutes(on: authenticated)
        setupMatchRoutes(on: authenticated)
        setupSponsorRoutes(on: authenticated)
        setupTeamRegistrationRoutes(on: authenticated)
        // MARK: - TEAM ROUTES
        setupTeamRoutes(on: authenticated)
        // MARK: - LEAGUE ROUTES
        setupLeagueRoutes(on: authenticated)
        // MARK: - PLAYER ROUTES
        setupPlayerRoutes(on: authenticated)
        // MARK: - NEWS ROUTES
        setupNewsRoutes(on: authenticated)
        // MARK: - STADIUM ROUTES
        setupStadiumRoutes(on: authenticated)
        // MARK: PUSH NOTIFICATIONS
        setupPushRoutes(on: authenticated)
        setupTransferRoutes(on: authenticated)
        // MARK: 💸 Team invoices (Rechnungen)
        setupInvoiceRoutes(on: authenticated)
        setupTransferSettingsRoutes(on: authenticated)
        setupLeaderboardRoutes(on: authenticated)
        setupFeeRoutes(on: authenticated)
        
        setupFollowRoutes(on: authenticated)
        setupVotingRoutes(on: authenticated)
        
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}

func buildLeagueTable(for league: League, on req: Request, onlyPrimarySeason: Bool = false) async throws -> [TableItem] {
    try await TeamStatisticsService.table(leagueID: league.requireID(), primaryOnly: onlyPrimarySeason, on: req.db).get()
}


struct GameDayGroup: Content {
    let gameday: Int
    /// The first scheduled match date for this matchday. The app can use this
    /// as the date displayed on the matchday card instead of creating a card
    /// for every calendar date.
    let date: Date?
    let matches: [AppModels.AppMatchOverview]
}

struct AppStadiumWithForecast: Content {
    let stadium: Stadium
    let forecast: Stadium.WeatherResponse
}
