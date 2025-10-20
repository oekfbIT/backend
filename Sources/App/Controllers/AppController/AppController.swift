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

        // MARK: - TEAM ROUTES
        route.get("team", "sid", ":sid", use: getTeamBySID)
        route.get("team", ":teamID", use: getTeamByID)
        route.get("team", ":teamID", "fixtures", use: getFixturesByTeamID)

        // MARK: - LEAGUE ROUTES
        route.get("league", ":leagueID", use: getLeagueByID)
        route.get("league", "code", ":code", use: getLeagueByCode)
        route.get("league", ":leagueID", "teams", use: getTeamsByLeagueID)
        route.get("league", "code", ":code", "teams", use: getTeamsByLeagueCode)
        route.get("league", ":leagueID", "fixtures", use: getFixturesByLeagueID)
        route.get("league", "code", ":code", "fixtures", use: getFixturesByLeagueCode)
        route.get("league", ":leagueID", "table", use: getLeagueTableByID)
        route.get("league", "primary", use: getAllPrimaryLeagueOverviews)

        // MARK: - PLAYER ROUTES
        route.get("player", ":playerID", use: getPlayerByID)
        route.get("player", "sid", ":sid", use: getPlayerBySID)

        // MARK: - MATCH ROUTES
        route.get("match", ":matchID", use: getMatchByID)

        // MARK: - NEWS ROUTES
        route.get("news", "all", use: getAllNews)
        route.get("news", "strafsenat", use: getStrafsenatNews)
        route.get("news", ":id", use: getNewsByID)

        // MARK: - STADIUM ROUTES
        route.get("stadium", "all", use: getAllStadiums)
        route.get("stadium", ":id", use: getStadiumByID)
        route.get("stadium", "bundesland", ":bundesland", use: getStadiumsByBundesland)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}

// MARK: - LEAGUE ENDPOINTS
extension AppController {
    // GET /app/league/primary
    func getAllPrimaryLeagueOverviews(req: Request) async throws -> [AppModels.AppLeagueOverview] {
        // 1️⃣ Fetch all primary seasons and preload their leagues
        let primarySeasons = try await Season.query(on: req.db)
            .filter(\.$primary == true)
            .with(\.$league)
            .all()

        // 2️⃣ Collect unique leagues and filter only visible ones
        let visibleLeagues = Dictionary(
            grouping: primarySeasons.compactMap { $0.league }
                .filter { $0.visibility == true }
        ) { league in
            league.id
        }.compactMap { $0.value.first }

        // 3️⃣ Convert to AppLeagueOverview models
        let overviews = try visibleLeagues.map { league in
            try league.toAppLeagueOverview()
        }

        // 4️⃣ Sort alphabetically by state, then name
        return overviews.sorted {
            if $0.state == $1.state {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.state.rawValue < $1.state.rawValue
        }
    }
 
    func getLeagueByID(req: Request) async throws -> AppModels.AppLeague {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let overview = try league.toAppLeagueOverview()

        // Map teams and attach cached stats
        let teams = try await league.teams.asyncMap { team in
            let stats = try await StatsCacheManager
                .getTeamStats(for: try team.requireID(), on: req.db)
                .get()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: overview,
                points: team.points,
                logo: team.logo,
                name: team.teamName,
                stats: stats
            )
        }

        // Build league table directly from teams
        var tableItems = try await buildLeagueTable(for: league, on: req, onlyPrimarySeason: true)

        // Sort by points, then goal difference
        tableItems.sort {
            if $0.points == $1.points {
                return $0.difference > $1.difference
            }
            return $0.points > $1.points
        }

        // Assign ranking positions
        for i in 0..<tableItems.count {
            tableItems[i].ranking = i + 1
        }

        return try league.toAppLeague(teams: teams, table: tableItems)
    }

    func getLeagueByCode(req: Request) async throws -> AppModels.AppLeague {
        guard let code = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league code.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$code == code)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let overview = try league.toAppLeagueOverview()

        // Map teams and attach cached stats
        let teams = try await league.teams.asyncMap { team in
            let stats = try await StatsCacheManager
                .getTeamStats(for: try team.requireID(), on: req.db)
                .get()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: overview,
                points: team.points,
                logo: team.logo,
                name: team.teamName,
                stats: stats
            )
        }

        // Build league table directly from teams
        var tableItems = teams.compactMap { team -> TableItem? in
            guard let stats = team.stats else { return nil }
            return TableItem(
                image: team.logo,
                name: team.name,
                points: team.points,
                id: team.id,
                goals: stats.totalScored,
                ranking: 0,
                wins: stats.wins,
                draws: stats.draws,
                losses: stats.losses,
                scored: stats.totalScored,
                against: stats.totalAgainst,
                difference: stats.goalDifference,
                form: [] // include this since TableItem now requires form
            )
        }

        // Sort by points, then goal difference
        tableItems.sort {
            if $0.points == $1.points {
                return $0.difference > $1.difference
            }
            return $0.points > $1.points
        }

        // Assign ranking positions
        for i in 0..<tableItems.count {
            tableItems[i].ranking = i + 1
        }

        return try league.toAppLeague(teams: teams, table: tableItems)
    }
    
    // GET /app/league/:leagueID/teams
    func getTeamsByLeagueID(req: Request) async throws -> [AppModels.AppTeamOverview] {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let leagueOverview = try league.toAppLeagueOverview()

        return try await league.teams.asyncMap { team in
            let stats = try await StatsCacheManager
                .getTeamStats(for: try team.requireID(), on: req.db)
                .get()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: leagueOverview,
                points: team.points,
                logo: team.logo,
                name: team.teamName,
                stats: stats
            )
        }
    }

    // GET /app/league/code/:code/teams
    func getTeamsByLeagueCode(req: Request) async throws -> [AppModels.AppTeamOverview] {
        guard let code = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league code.")
        }

        guard let league = try await League.query(on: req.db)
            .filter(\.$code == code)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let leagueOverview = try league.toAppLeagueOverview()

        return try await league.teams.asyncMap { team in
            let stats = try await StatsCacheManager
                .getTeamStats(for: try team.requireID(), on: req.db)
                .get()

            return AppModels.AppTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: leagueOverview,
                points: team.points,
                logo: team.logo,
                name: team.teamName,
                stats: stats
            )
        }
    }
    
    // GET /app/league/:leagueID/fixtures
    func getFixturesByLeagueID(req: Request) async throws -> [GameDayGroup] {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        // 1️⃣ Load league
        guard let league = try await League.find(leagueID, on: req.db) else {
            throw Abort(.notFound, reason: "League not found.")
        }

        // 2️⃣ Get all primary seasons for this league
        let seasons = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$primary == true)
            .all()

        let seasonIDs = try seasons.map { try $0.requireID() }

        // 3️⃣ Get all matches from those seasons
        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id ~~ seasonIDs)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        // 4️⃣ Group by gameday and sort
        let grouped = Dictionary(grouping: matches) { $0.details.gameday }
            .sorted { $0.key < $1.key }

        let leagueOverview = try league.toAppLeagueOverview()

        // 5️⃣ Convert into compact [GameDayGroup]
        let groups: [GameDayGroup] = try await grouped.asyncMap { (day, matchesForDay) in
            let sortedMatches = matchesForDay.sorted {
                ($0.details.date ?? .distantPast) < ($1.details.date ?? .distantPast)
            }

            let appMatches = try await sortedMatches.asyncMap { match in
                let home = match.homeTeam
                let away = match.awayTeam

                let homeOverview = AppModels.AppTeamOverview(
                    id: try home.requireID(),
                    sid: home.sid ?? "",
                    league: leagueOverview,
                    points: home.points,
                    logo: home.logo,
                    name: home.teamName,
                    stats: nil
                )

                let awayOverview = AppModels.AppTeamOverview(
                    id: try away.requireID(),
                    sid: away.sid ?? "",
                    league: leagueOverview,
                    points: away.points,
                    logo: away.logo,
                    name: away.teamName,
                    stats: nil
                )

                let season = try match.season?.toAppSeason() ?? AppModels.AppSeason(
                    id: UUID().uuidString,
                    league: league.name,
                    leagueId: try league.requireID(),
                    name: "Primary"
                )

                return AppModels.AppMatchOverview(
                    id: try match.requireID(),
                    details: match.details,
                    score: match.score,
                    season: season,
                    away: awayOverview,
                    home: homeOverview,
                    homeBlanket: (match.homeBlanket ?? Blankett(
                        name: home.teamName,
                        dress: home.trikot.home,
                        logo: home.logo,
                        players: []
                    )).toMini(),
                    awayBlanket: (match.awayBlanket ?? Blankett(
                        name: away.teamName,
                        dress: away.trikot.away,
                        logo: away.logo,
                        players: []
                    )).toMini(),
                    status: match.status
                )
            }

            return GameDayGroup(gameday: day, matches: appMatches)
        }

        return groups
    }

    // GET /app/league/code/:code/fixtures
    func getFixturesByLeagueCode(req: Request) async throws -> [GameDayGroup] {
        guard let code = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league code.")
        }

        // 1️⃣ Find league by code
        guard let league = try await League.query(on: req.db)
            .filter(\.$code == code)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        let leagueID = try league.requireID()

        // 2️⃣ Get all primary seasons
        let seasons = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$primary == true)
            .all()

        let seasonIDs = try seasons.map { try $0.requireID() }

        // 3️⃣ Get matches
        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id ~~ seasonIDs)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        // 4️⃣ Group and sort
        let grouped = Dictionary(grouping: matches) { $0.details.gameday }
            .sorted { $0.key < $1.key }

        let leagueOverview = try league.toAppLeagueOverview()

        // 5️⃣ Convert to compact AppMatchOverview
        let groups: [GameDayGroup] = try await grouped.asyncMap { (day, matchesForDay) in
            let sortedMatches = matchesForDay.sorted {
                ($0.details.date ?? .distantPast) < ($1.details.date ?? .distantPast)
            }

            let appMatches = try await sortedMatches.asyncMap { match in
                let home = match.homeTeam
                let away = match.awayTeam

                let homeOverview = AppModels.AppTeamOverview(
                    id: try home.requireID(),
                    sid: home.sid ?? "",
                    league: leagueOverview,
                    points: home.points,
                    logo: home.logo,
                    name: home.teamName,
                    stats: nil
                )

                let awayOverview = AppModels.AppTeamOverview(
                    id: try away.requireID(),
                    sid: away.sid ?? "",
                    league: leagueOverview,
                    points: away.points,
                    logo: away.logo,
                    name: away.teamName,
                    stats: nil
                )

                let season = try match.season?.toAppSeason() ?? AppModels.AppSeason(
                    id: UUID().uuidString,
                    league: league.name,
                    leagueId: try league.requireID(),
                    name: "Primary"
                )

                return AppModels.AppMatchOverview(
                    id: try match.requireID(),
                    details: match.details,
                    score: match.score,
                    season: season,
                    away: awayOverview,
                    home: homeOverview,
                    homeBlanket: (match.homeBlanket ?? Blankett(
                        name: home.teamName,
                        dress: home.trikot.home,
                        logo: home.logo,
                        players: []
                    )).toMini(),
                    awayBlanket: (match.awayBlanket ?? Blankett(
                        name: away.teamName,
                        dress: away.trikot.away,
                        logo: away.logo,
                        players: []
                    )).toMini(),
                    status: match.status
                )
            }

            return GameDayGroup(gameday: day, matches: appMatches)
        }

        return groups
    }
    
    // MARK: - Get League Table by League ID (Primary Season Only)
    func getLeagueTableByID(req: Request) async throws -> [TableItem] {
        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }

        // 1️⃣ Load the league and its teams
        guard let league = try await League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$teams)
            .first()
        else {
            throw Abort(.notFound, reason: "League not found.")
        }

        // 2️⃣ Ensure there is at least one primary season for this league
        let hasPrimarySeason = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$primary == true)
            .count() > 0

        guard hasPrimarySeason else {
            throw Abort(.notFound, reason: "No primary season found for this league.")
        }

        // 3️⃣ Build league table based on primary season only
        var tableItems = try await buildLeagueTable(for: league, on: req, onlyPrimarySeason: true)

        // 4️⃣ Sort by points, then goal difference
        tableItems.sort {
            if $0.points == $1.points {
                return $0.difference > $1.difference
            }
            return $0.points > $1.points
        }

        // 5️⃣ Assign ranking positions
        for i in 0..<tableItems.count {
            tableItems[i].ranking = i + 1
        }

        return tableItems
    }

}

// MARK: - PLAYER ENDPOINTS
extension AppController {
    // MARK: Get Player by ID
    func getPlayerByID(req: Request) async throws -> AppModels.AppPlayer {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid player ID.")
        }

        // Only include team relation
        guard let player = try await Player.query(on: req.db)
            .filter(\.$id == playerID)
            .with(\.$team)
            .first()
        else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        guard let team = player.team else {
            throw Abort(.notFound, reason: "Team not found for this player.")
        }

        // Build league + team overview
        let leagueOverview = try team.league?.toAppLeagueOverview()
        ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await team.toAppTeamOverview(league: leagueOverview, req: req).get()

        // Use cached stats
        let stats = try await StatsCacheManager
            .getPlayerStats(for: try player.requireID(), on: req.db)
            .get()

        return try player.toAppPlayer(team: teamOverview, stats: stats)
    }

    // MARK: Get Player by SID
    func getPlayerBySID(req: Request) async throws -> AppModels.AppPlayer {
        guard let sid = req.parameters.get("sid", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid player SID.")
        }

        // Only include team relation
        guard let player = try await Player.query(on: req.db)
            .filter(\.$sid == sid)
            .with(\.$team)
            .first()
        else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        guard let team = player.team else {
            throw Abort(.notFound, reason: "Team not found for this player.")
        }

        // Build league + team overview
        let leagueOverview = try team.league?.toAppLeagueOverview()
        ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await team.toAppTeamOverview(league: leagueOverview, req: req).get()

        // Use cached stats
        let stats = try await StatsCacheManager
            .getPlayerStats(for: try player.requireID(), on: req.db)
            .get()

        return try player.toAppPlayer(team: teamOverview, stats: stats)
    }
}

// MARK: - TEAM ENDPOINTS
extension AppController {
    // GET /app/team/:teamID
    func getTeamByID(req: Request) async throws -> AppModels.AppTeam {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID.")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$league)
            .with(\.$players)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        let leagueOverview = try team.league?.toAppLeagueOverview()
        ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await team.toAppTeamOverview(league: leagueOverview, req: req).get()

        let playerOverviews = try await team.players.asyncMap {
            try await $0.toAppPlayerOverview(team: teamOverview)
        }

        return try await team.toAppTeam(league: leagueOverview, players: playerOverviews, req: req).get()
    }

    // GET /app/team/sid/:sid
    func getTeamBySID(req: Request) async throws -> AppModels.AppTeam {
        guard let sid = req.parameters.get("sid", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team SID.")
        }

        guard let team = try await Team.query(on: req.db)
            .filter(\.$sid == sid)
            .with(\.$league)
            .with(\.$players)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        let leagueOverview = try team.league?.toAppLeagueOverview()
        ?? AppModels.AppLeagueOverview(id: UUID(), name: "Unknown", code: "", state: .wien)

        let teamOverview = try await team.toAppTeamOverview(league: leagueOverview, req: req).get()

        let playerOverviews = try await team.players.asyncMap {
            try await $0.toAppPlayerOverview(team: teamOverview)
        }

        return try await team.toAppTeam(league: leagueOverview, players: playerOverviews, req: req).get()
    }
    
    func getFixturesByTeamID(req: Request) async throws -> [GameDayGroup] {
        guard let teamID = req.parameters.get("teamID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID.")
        }

        // 1️⃣ Load the team and its league
        guard let team = try await Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$league)
            .first()
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        guard let league = team.league else {
            throw Abort(.notFound, reason: "No league associated with this team.")
        }

        // Optional query parameter ?onlyPrimary=true
        let onlyPrimary = (try? req.query.get(Bool.self, at: "onlyPrimary")) ?? false

        // 2️⃣ Fetch relevant seasons
        var seasonQuery = Season.query(on: req.db)
            .filter(\.$league.$id == league.id)

        if onlyPrimary {
            seasonQuery = seasonQuery.filter(\.$primary == true)
        }

        let seasons = try await seasonQuery.all()
        let seasonIDs = try seasons.map { try $0.requireID() }

        // 3️⃣ Fetch matches where this team played (home or away)
        let matches = try await Match.query(on: req.db)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                or.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$season.$id ~~ seasonIDs)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .all()

        // 4️⃣ Group by gameday and sort by date
        let grouped = Dictionary(grouping: matches) { $0.details.gameday }
            .sorted { $0.key < $1.key }

        let leagueOverview = try league.toAppLeagueOverview()
        var groups: [GameDayGroup] = []

        for (day, matchesForDay) in grouped {
            let sortedMatches = matchesForDay.sorted {
                ($0.details.date ?? .distantPast) < ($1.details.date ?? .distantPast)
            }

            let appMatches: [AppModels.AppMatchOverview] = try await sortedMatches.asyncMap { match in
                let home = match.homeTeam
                let away = match.awayTeam

                let homeOverview = AppModels.AppTeamOverview(
                    id: try home.requireID(),
                    sid: home.sid ?? "",
                    league: leagueOverview,
                    points: home.points,
                    logo: home.logo,
                    name: home.teamName,
                    stats: nil
                )

                let awayOverview = AppModels.AppTeamOverview(
                    id: try away.requireID(),
                    sid: away.sid ?? "",
                    league: leagueOverview,
                    points: away.points,
                    logo: away.logo,
                    name: away.teamName,
                    stats: nil
                )

                let season = try match.season?.toAppSeason() ?? AppModels.AppSeason(
                    id: UUID().uuidString,
                    league: league.name,
                    leagueId: try league.requireID(),
                    name: "Primary"
                )

                return AppModels.AppMatchOverview(
                    id: try match.requireID(),
                    details: match.details,
                    score: match.score,
                    season: season,
                    away: awayOverview,
                    home: homeOverview,
                    homeBlanket: (match.homeBlanket ?? Blankett(
                        name: home.teamName,
                        dress: home.trikot.home,
                        logo: home.logo,
                        players: []
                    )).toMini(),
                    awayBlanket: (match.awayBlanket ?? Blankett(
                        name: away.teamName,
                        dress: away.trikot.away,
                        logo: away.logo,
                        players: []
                    )).toMini(),
                    status: match.status
                )
            }

            groups.append(GameDayGroup(gameday: day, matches: appMatches))
        }

        return groups
    }
}
    
// MARK: - MATCH ENDPOINTS
extension AppController {
    // GET /app/match/:matchID
    func getMatchByID(req: Request) async throws -> AppModels.AppMatch {
        guard let matchID = req.parameters.get("matchID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid match ID.")
        }

        // 1️⃣ Load match with all needed relations (including nested league)
        guard let match = try await (
            Match.query(on: req.db)
                .filter(\.$id == matchID)
                .with(\.$homeTeam)
                .with(\.$awayTeam)
                .with(\.$season) { $0.with(\.$league) }
                .with(\.$events)
                .first()
        ) else {
            throw Abort(.notFound, reason: "Match not found.")
        }

        // 2️⃣ Prepare league + season context
        guard let season = match.season else {
            throw Abort(.notFound, reason: "Season not found for this match.")
        }

        guard let league = season.league else {
            throw Abort(.notFound, reason: "League not found for this match.")
        }

        let leagueOverview = try league.toAppLeagueOverview()
        let appSeason = try season.toAppSeason()

        // 3️⃣ Build AppTeamOverview for home and away
        let home = match.homeTeam
        let away = match.awayTeam

        let homeOverview = AppModels.AppTeamOverview(
            id: try home.requireID(),
            sid: home.sid ?? "",
            league: leagueOverview,
            points: home.points,
            logo: home.logo,
            name: home.teamName,
            stats: try? await StatsCacheManager
                .getTeamStats(for: try home.requireID(), on: req.db)
                .get()
        )

        let awayOverview = AppModels.AppTeamOverview(
            id: try away.requireID(),
            sid: away.sid ?? "",
            league: leagueOverview,
            points: away.points,
            logo: away.logo,
            name: away.teamName,
            stats: try? await StatsCacheManager
                .getTeamStats(for: try away.requireID(), on: req.db)
                .get()
        )

        // 4️⃣ Map events
        let appEvents: [AppModels.AppMatchEvent] = try await match.events.asyncMap {
            try await $0.toAppMatchEvent(on: req)
        }

        // 5️⃣ Return full AppMatch
        return AppModels.AppMatch(
            id: try match.requireID(),
            details: match.details,
            score: match.score,
            season: appSeason,
            away: awayOverview,
            home: homeOverview,
            homeBlanket: match.homeBlanket ?? Blankett(
                name: home.teamName,
                dress: home.trikot.home,
                logo: home.logo,
                players: []
            ),
            awayBlanket: match.awayBlanket ?? Blankett(
                name: away.teamName,
                dress: away.trikot.away,
                logo: away.logo,
                players: []
            ),
            events: appEvents,
            status: match.status,
            firstHalfStartDate: match.firstHalfStartDate,
            secondHalfStartDate: match.secondHalfStartDate,
            firstHalfEndDate: match.firstHalfEndDate,
            secondHalfEndDate: match.secondHalfEndDate
        )
    }
}

// MARK: - News Endpoints
extension AppController {

    // 1️⃣ GET /app/news/all
    func getAllNews(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .filter(\.$tag == "Alle")
            .sort(\.$created, .descending)
            .all()
    }

    // 2️⃣ GET /app/news/strafsenat
    func getStrafsenatNews(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .filter(\.$tag == "strafsenat ")
            .sort(\.$created, .descending)
            .all()
    }

    // 3️⃣ GET /app/news/:id
    func getNewsByID(req: Request) async throws -> NewsItem {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid news ID.")
        }

        guard let news = try await NewsItem.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "News item not found.")
        }

        return news
    }
}

// MARK: - Stadium Endpoints
extension AppController {

    func getAllStadiums(req: Request) async throws -> [Stadium] {
        try await Stadium.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()
    }

    // GET /app/stadium/:stadiumID
    func getStadiumByID(req: Request) async throws -> AppStadiumWithForecast {
        // 1️⃣ Extract the stadium ID as a String (MongoDB uses string-based _id)
        guard let stadiumID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid stadium ID.")
        }

        // 2️⃣ Find stadium by ID
        guard let stadium = try await Stadium.find(stadiumID, on: req.db) else {
            throw Abort(.notFound, reason: "Stadium not found.")
        }

        // 3️⃣ Fetch live weather forecast
        let forecast = try await stadium.getWeatherForecast(on: req)

        // 4️⃣ Combine both in a single response
        return AppStadiumWithForecast(stadium: stadium, forecast: forecast)
    }

    // 3️⃣ GET /app/stadiums/bundesland/:bundesland
    func getStadiumsByBundesland(req: Request) async throws -> [Stadium] {
        guard let bundeslandRaw = req.parameters.get("bundesland", as: String.self),
              let bundesland = Bundesland(rawValue: bundeslandRaw) else {
            throw Abort(.badRequest, reason: "Invalid or missing Bundesland.")
        }

        return try await Stadium.query(on: req.db)
            .filter(\.$bundesland == bundesland)
            .sort(\.$name, .ascending)
            .all()
    }
}


private func buildLeagueTable(
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
