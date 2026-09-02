import Foundation
import Fluent
import Vapor

extension AdminController {
    struct SearchItem: Content {
        let id: UUID
        let type: String
        let title: String
        let subtitle: String?
        let url: String
        let image: String?
    }

    struct SearchResponse: Content {
        let query: String
        let total: Int
        let items: [SearchItem]
    }

    /// Access-aware global admin search. This route is mounted below the
    /// authenticated AdminOnlyMiddleware group in AdminController.
    /// GET /admin/search?query=...&limit=...
    func setupSearchRoutes(on root: RoutesBuilder) {
        root.get("search", use: globalSearch)
    }

    func globalSearch(req: Request) async throws -> SearchResponse {
        let suppliedQuery = try req.query.get(String.self, at: "query")
        let query = suppliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            throw Abort(.badRequest, reason: "Search query must contain at least two characters.")
        }

        let requestedLimit = (try? req.query.get(Int.self, at: "limit")) ?? 6
        let limit = min(max(requestedLimit, 1), 10)
        let pattern = NSRegularExpression.escapedPattern(for: query)

        async let playersFuture = Player.query(on: req.db).mongoRegex("name", pattern).limit(limit).all()
        async let refereesFuture = Referee.query(on: req.db).mongoRegex("name", pattern).limit(limit).all()
        async let teamsFuture = Team.query(on: req.db).mongoRegex("teamName", pattern).limit(limit).all()
        async let leaguesFuture = League.query(on: req.db).mongoRegex("name", pattern).limit(limit).all()
        async let seasonsFuture = Season.query(on: req.db).mongoRegex("name", pattern).limit(limit).all()
        async let stadiumsFuture = Stadium.query(on: req.db).mongoRegex("name", pattern).limit(limit).all()
        async let usersByFirstNameFuture = User.query(on: req.db).mongoRegex("firstName", pattern).limit(limit).all()
        async let usersByLastNameFuture = User.query(on: req.db).mongoRegex("lastName", pattern).limit(limit).all()
        async let usersByEmailFuture = User.query(on: req.db).mongoRegex("email", pattern).limit(limit).all()

        let (players, referees, teams, leagues, seasons, stadiums, usersByFirstName, usersByLastName, usersByEmail) = try await (
            playersFuture, refereesFuture, teamsFuture, leaguesFuture, seasonsFuture, stadiumsFuture,
            usersByFirstNameFuture, usersByLastNameFuture, usersByEmailFuture
        )

        var items: [SearchItem] = []
        items += try players.map {
            SearchItem(id: try $0.requireID(), type: "player", title: $0.name,
                       subtitle: [$0.sid, $0.nationality].filter { !$0.isEmpty }.joined(separator: " · "),
                       url: "/admin/players_detail/\(try $0.requireID())", image: $0.image)
        }
        items += try referees.map {
            SearchItem(id: try $0.requireID(), type: "referee", title: $0.name ?? "Schiedsrichter",
                       subtitle: $0.phone, url: "/admin/referee_detail/\(try $0.requireID())", image: $0.image)
        }
        items += try teams.map {
            SearchItem(id: try $0.requireID(), type: "team", title: $0.teamName,
                       subtitle: [$0.sid, $0.leagueCode].compactMap { $0 }.joined(separator: " · "),
                       url: "/admin/team_detail/\(try $0.requireID())", image: $0.logo)
        }
        items += try leagues.map {
            SearchItem(id: try $0.requireID(), type: "league", title: $0.name,
                       subtitle: $0.code, url: "/admin/league_detail/\(try $0.requireID())", image: nil)
        }
        items += try seasons.map {
            SearchItem(id: try $0.requireID(), type: "season", title: $0.name,
                       subtitle: "Saison", url: "/admin/season_detail/\(try $0.requireID())", image: nil)
        }
        items += try stadiums.map {
            SearchItem(id: try $0.requireID(), type: "stadium", title: $0.name,
                       subtitle: $0.address, url: "/admin/stadium_detail/\(try $0.requireID())", image: $0.image)
        }

        var seenUserIDs = Set<UUID>()
        let users = (usersByFirstName + usersByLastName + usersByEmail).filter { user in
            guard let id = user.id, seenUserIDs.insert(id).inserted else { return false }
            return true
        }.prefix(limit)
        items += try users.map {
            SearchItem(id: try $0.requireID(), type: "user", title: "\($0.firstName) \($0.lastName)",
                       subtitle: "\($0.email) · \($0.type.rawValue)",
                       url: "/admin/user_detail/\(try $0.requireID())", image: nil)
        }

        let sorted = items.sorted {
            let leftStarts = $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame || $0.title.lowercased().hasPrefix(query.lowercased())
            let rightStarts = $1.title.localizedCaseInsensitiveCompare(query) == .orderedSame || $1.title.lowercased().hasPrefix(query.lowercased())
            if leftStarts != rightStarts { return leftStarts }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return SearchResponse(query: query, total: sorted.count, items: sorted)
    }
}
