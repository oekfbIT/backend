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
        // MARK: - AUTH ROUTES
        try setupAuthRoutes(on: route)
        // MARK: - SEARCH ROUTES
        try setupSearchRoutes(on: route)
        try setupChatRoutes(on: route)
        setupMatchRoutes(on: route)
        setupSponsorRoutes(on: route)
        setupTeamRegistrationRoutes(on: route)
        // MARK: - TEAM ROUTES
        setupTeamRoutes(on: route)
        // MARK: - LEAGUE ROUTES
        setupLeagueRoutes(on: route)
        // MARK: - PLAYER ROUTES
        setupPlayerRoutes(on: route) 
        // MARK: - NEWS ROUTES
        setupNewsRoutes(on: route)
        // MARK: - STADIUM ROUTES
        setupStadiumRoutes(on: route)
        // MARK: PUSH NOTIFICATIONS
        setupPushRoutes(on: route)
        setupTransferRoutes(on: route)
        // MARK: 💸 Team invoices (Rechnungen)
        setupInvoiceRoutes(on: route)
        setupTransferSettingsRoutes(on: route)
        setupLeaderboardRoutes(on: route)
        
        setupFollowRoutes(on: route)
        setupVotingRoutes(on: route)
        
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
