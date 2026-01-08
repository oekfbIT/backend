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
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}

func buildLeagueTable(
    for league: League,
    on req: Request,
    onlyPrimarySeason: Bool = false
) async throws -> [TableItem] {
    try await league.teams.asyncMap { team in
        let stats = try await Team.getTeamStats(
            teamID: try team.requireID(),
            db: req.db,
            onlyPrimarySeason: onlyPrimarySeason
        ).get()

        let form = try await Team.getRecentForm(
            for: try team.requireID(),
            on: req.db,
            onlyPrimarySeason: onlyPrimarySeason
        )

        return TableItem(
            image: team.logo,
            name: team.teamName,
            points: team.points,
            id: try team.requireID(),
            goals: stats.totalScored,
            ranking: 0,
            wins: stats.wins,
            draws: stats.draws,
            losses: stats.losses,
            scored: stats.totalScored,
            against: stats.totalAgainst,
            difference: stats.goalDifference,
            form: form
        )
    }
}


struct GameDayGroup: Content {
    let gameday: Int
    let matches: [AppModels.AppMatchOverview]
}

struct AppStadiumWithForecast: Content {
    let stadium: Stadium
    let forecast: Stadium.WeatherResponse
}
