import Vapor
import Fluent 

final class ClientController: RouteCollection {
    let path: String
    
    init(path: String) {
        self.path = path
    }
    
    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: path))
        
        route.get("home", "league", ":code", use: fetchHomepageData)
        route.get("selection", use: fetchLeagueSelection)
        route.get("clubs", "league", ":code", use: fetchLeagueClubs)
        route.get("clubs", "detail", ":id", use: fetchClub)
        route.get("teamseaction", "detail", ":id", use: teamSectionClub)
        route.get("club", "trainer", ":id", use: teamTrainer)
        route.get("table", "league", ":code", use: fetchtable)
        route.get("team", "league", ":id", use: fetchLeague)
        route.get("news", "league", ":code", use: fetchNews)
        route.get("transfers", use: fetchTransfers)
        route.get("news", "detail", ":id", use: fetchNewsItem)
        route.get("matches", "league", ":code", use: fetchFirstSeasonMatches)
        // First, define a route that fetches a single match by its ID and includes the events:
        route.get("match", "detail", ":id", use: fetchMatch)
        route.get("player", "detail", ":id", use: fetchPlayer)
        route.get("search", use: search)
        
        route.get("leaderboard", ":id", "goal", use: getGoalLeaderBoardSeason)
        route.get("leaderboard", ":id", "redCard", use: getRedCardLeaderBoardSeason)
        route.get("leaderboard",":id", "yellowCard", use: getYellowCardLeaderBoardSeason)
        route.get("leaderboard",":id", "yellowRedCard", use: getYellowRedCardLeaderBoardSeason)
        route.get("blocked", "league", ":code", use: blockedPlayers)
        route.get("livescore",use: getLivescoreShort)
        route.get("team", ":id", "nextmatch", use: getTeamNextmatch)

        // Current season table at the root (not behind `path` group). If you want it under the same group, change to `route.get(...)`.
        route.get("leagues", ":code", "current", "table", use: getcurrentSeasonTable)
        // e.g. in routes.swift
        route.get("matches", "league", ":code", "primary", use: fetchPrimarySeasonMatches)
        route.get("matches", "league", ":code", "index", use: fetchAllSeasonMatches)
        
//        route.get("leaderboard", ":id", "goal", "primary", use: getGoalLeaderBoardPrimarySeason)
//        route.get("leaderboard", ":id", "redCard", "primary", use: getRedCardLeaderBoardPrimarySeason)
//        route.get("leaderboard", ":id", "yellowCard", "primary", use: getYellowCardLeaderBoardPrimarySeason)
//        route.get("leaderboard", ":id", "yellowRedCard", "primary", use: getYellowRedCardLeaderBoardPrimarySeason)

    }
    
    // MARK: Current Season Table (Primary Season)
    func getcurrentSeasonTable(req: Request) -> EventLoopFuture<[TableItem]> {
        guard let code = req.parameters.get("code", as: String.self) else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing league code"))
        }

        return fetchLeagueAndCurrentSeason(code, db: req.db).flatMap { (league, season) in
            season.$matches.query(on: req.db).all().and(league.$teams.query(on: req.db).all())
                .map { (matches, teams) in

                    func stats(for teamID: UUID, in matches: [Match]) -> (wins: Int, draws: Int, losses: Int, scored: Int, against: Int) {
                        var w = 0, d = 0, l = 0, s = 0, a = 0

                        for m in matches {
                            let homeId = m.$homeTeam.id
                            let awayId = m.$awayTeam.id

                            guard homeId == teamID || awayId == teamID else { continue }

                            switch m.status {
                            case .pending, .first, .halftime, .second:
                                continue
                            default:
                                break
                            }

                            let isHome = homeId == teamID
                            let mine = isHome ? m.score.home : m.score.away
                            let opp = isHome ? m.score.away : m.score.home

                            s += mine
                            a += opp

                            if mine > opp { w += 1 }
                            else if mine == opp { d += 1 }
                            else { l += 1 }
                        }

                        return (w, d, l, s, a)
                    }

                    var rows: [(item: TableItem, sortingPoints: Double)] = teams.compactMap { team in
                        guard let tid = team.id else { return nil }

                        let st = stats(for: tid, in: matches)
                        let calculatedPoints = st.wins * 3 + st.draws

                        let item = TableItem(
                            image: team.logo,
                            name: team.teamName,
                            points: calculatedPoints,
                            id: tid,
                            goals: st.scored,
                            ranking: 0,
                            wins: st.wins,
                            draws: st.draws,
                            losses: st.losses,
                            scored: st.scored,
                            against: st.against,
                            difference: st.scored - st.against,
                            form: []
                        )

                        return (
                            item: item,
                            sortingPoints: team.hiddenpoints ?? Double(calculatedPoints)
                        )
                    }

                    rows.sort {
                        if $0.sortingPoints == $1.sortingPoints {
                            return $0.item.difference > $1.item.difference
                        }

                        return $0.sortingPoints > $1.sortingPoints
                    }

                    var table = rows.map { $0.item }

                    for i in table.indices {
                        table[i].ranking = i + 1
                    }

                    return table
                }
        }
    }
    // MARK: League Selection
    func fetchLeagueSelection(req: Request) throws -> EventLoopFuture<[PublicLeagueOverview]> {
        return League.query(on: req.db).all().mapEach { league in
            PublicLeagueOverview(
                id: league.id,
                state: league.state,
                code: league.code,
                teamcount: league.teamcount,
                name: league.name,
                visibility: league.visibility
            )
        }
    }

    // MARK: League Selection
    func fetchTransfers(req: Request) throws -> EventLoopFuture<[Transfer]> {
        return Transfer.query(on: req.db)
            .filter(\.$status == .angenommen)
            .filter(\.$originName != nil)
            .filter(\.$originImage != nil)
            .all()
    }

    // MARK: Homepage
    func fetchHomepageData(req: Request) throws -> EventLoopFuture<HomepageResponse> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }
        
        let leagueFuture = fetchLeagueByCode(leagueCode, db: req.db) // Wrapped Value
        let teamsFuture = leagueFuture.flatMap { self.fetchTeams(for: $0, db: req.db) }
        let newsFuture = leagueFuture.flatMap { self.fetchLeagueNews(league: $0, code: leagueCode, db: req.db) }
        let seasonsFuture = leagueFuture.flatMap { self.fetchSeasons(for: $0, db: req.db) }
        
        return leagueFuture.flatMap { league in
            teamsFuture.and(newsFuture).and(seasonsFuture).map { result in
                let (teams, newsItems, seasons) = (result.0.0, result.0.1, result.1)
                let upcomingMatches = self.getUpcomingMatchesWithinNext7Days(from: seasons)
                let upcomingMatchesShort = self.mapMatchesToShort(upcomingMatches)
                let publicTeams = self.mapTeamsToPublic(teams)
                
                return HomepageResponse(
                    data: league.homepagedata,
                    teams: publicTeams,
                    news: newsItems,
                    upcoming: upcomingMatchesShort,
                    league: league // Pass the actual league object here
                )
            }
        }
    }

    // MARK: Club
    func fetchLeagueClubs(req: Request) throws -> EventLoopFuture<[PublicTeamShort]> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }
        
        return fetchLeagueByCode(leagueCode, db: req.db).flatMap { league in
            self.fetchTeams(for: league, db: req.db).map { teams in
                teams.map { team in
                    PublicTeamShort(
                        id: team.id,
                        sid: team.sid,
                        logo: team.logo,
                        points: team.points,
                        teamName: team.teamName
                    )
                }
            }
        }
    }
    
    // MARK: Table
    func fetchtable(req: Request) -> EventLoopFuture<[TableItem]> {
        
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid or missing league code"))
        }
        
        return fetchLeagueByCode(leagueCode, db: req.db).flatMap { league in
            league.$teams.query(on: req.db).all().flatMap { teams in
                let teamStatsFutures = teams.map { team in
                    self.getTeamStats(teamID: team.id!, db: req.db).map { stats in (team, stats) }
                }
                
                return req.eventLoop.flatten(teamStatsFutures).map { teamStatsPairs in
                    var tableItems: [TableItem] = []
                    
                    for (team, stats) in teamStatsPairs {
                        let tableItem = TableItem(
                            image: team.logo,
                            name: team.teamName,
                            points: team.points,
                            id: team.id!,
                            goals: stats.totalScored,
                            ranking: 0,
                            wins: stats.wins,
                            draws: stats.draws,
                            losses: stats.losses,
                            scored: stats.totalScored,
                            against: stats.totalAgainst,
                            difference: stats.goalDifference, form: []
                        )
                        tableItems.append(tableItem)
                    }
                    
                    tableItems.sort {
                        if $0.points == $1.points {
                            return $0.difference > $1.difference
                        }
                        return $0.points > $1.points
                    }
                    
                    for i in 0..<tableItems.count {
                        tableItems[i].ranking = i + 1
                    }
                    
                    return tableItems
                }
            }
        }
    }
    
    // MARK: News
    func fetchNews(req: Request) throws -> EventLoopFuture<[NewsItem]> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }
        
        return fetchLeagueByCode(leagueCode, db: req.db).flatMap { league in
            self.fetchLeagueNews(league: league, code: leagueCode, db: req.db)
        }
    }
    
    // MARK: News Detail
    func fetchNewsItem(req: Request) throws -> EventLoopFuture<NewsItem> {
        guard let newsItemID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing news item ID")
        }
        return NewsItem.find(newsItemID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "News item not found"))
    }
    
    // MARK: Gameday
    func fetchFirstSeasonMatches(req: Request) throws -> EventLoopFuture<[PublicMatchShort]> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }

        return fetchLeagueByCode(leagueCode, db: req.db).flatMap { league in
            league.$seasons.query(on: req.db)
                .with(\.$matches) { match in
                    match.with(\.$homeTeam)
                         .with(\.$awayTeam)
                }
                .all()
                .map { seasons in
                    guard let firstSeason = seasons.first else {
                        return []
                    }
                    return self.mapMatchesToShort(firstSeason.matches)
                }
        }
    }
    
    func fetchPrimarySeasonMatches(req: Request) throws -> EventLoopFuture<[PublicMatchShort]> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }

        return fetchLeagueByCode(leagueCode, db: req.db).flatMap { league in
            league.$seasons.query(on: req.db)
                .filter(\.$primary == true)
                .with(\.$matches) { match in
                    match.with(\.$homeTeam)
                         .with(\.$awayTeam)
                }
                .first()
                .map { season in
                    guard let primarySeason = season else {
                        return []
                    }
                    return self.mapMatchesToShort(primarySeason.matches)
                }
        }
    }
    
    func fetchAllSeasonMatches(req: Request) throws -> EventLoopFuture<[Season]> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }

        return fetchLeagueByCode(leagueCode, db: req.db).flatMap { league in
            league.$seasons.query(on: req.db)
                .with(\.$matches)
                .all()
        }
    }

    // MARK: Match Detail
    func fetchMatch(req: Request) throws -> EventLoopFuture<PublicMatch> {
        guard let matchID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing match ID")
        }
        return Match.find(matchID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Match not found"))
            .flatMap { match in
                match.$season.load(on: req.db).and(match.$referee.load(on: req.db)).flatMap { _, _ in
                    match.$events.query(on: req.db)
                        .all()
                        .map { events in
                            PublicMatch(
                                id: match.id,
                                details: match.details,
                                referee: match.$referee.wrappedValue,
                                season: match.$season.wrappedValue,
                                homeBlanket: match.homeBlanket,
                                awayBlanket: match.awayBlanket,
                                events: events,
                                score: match.score,
                                status: match.status,
                                bericht: match.bericht,
                                firstHalfDate: match.firstHalfStartDate,
                                secondHalfDate: match.secondHalfStartDate
                                
                            )
                        }
                }
            }
    }

    private func fetchMatchesForPlayer(_ playerID: UUID, db: Database) -> EventLoopFuture<[Match]> {
        return Match.query(on: db)
            .all()
            .map { matches in
                matches.filter { match in
                    let homePlayers = match.homeBlanket?.players.map { $0.id } ?? []
                    let awayPlayers = match.awayBlanket?.players.map { $0.id } ?? []
                    return homePlayers.contains(playerID) || awayPlayers.contains(playerID)
                }
            }
    }
    
// MARK: BLOCKED PLAYERS
    func blockedPlayers(req: Request) throws -> EventLoopFuture<[SperrItem]> {
        // Extract league code from the request parameters
        guard let leagueCode = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "League code is required")
        }

        // Query to fetch players with blockdate in the future and eligibility "Gesperrt"
        return League.query(on: req.db)
            .filter(\.$code == leagueCode) // Filter leagues by code
            .with(\.$teams) { team in
                team.with(\.$players) // Fetch all players associated with the teams in the league
            }
            .first()
            .flatMapThrowing { league in
                guard let teams = league?.teams else { return [] }
                
                let currentDate = Date.viennaNow

                // Collect all players that meet the conditions
                let blockedPlayers = teams.flatMap { team in
                    team.players.compactMap { player -> SperrItem? in
                        guard let blockdate = player.blockdate, blockdate > currentDate else { return nil }
                        guard player.eligibility == .Gesperrt else { return nil }
                        
                        return SperrItem(
                            playerName: player.name,
                            playerImage: player.image,
                            playerSid: player.sid,
                            playerid: player.id,
                            playerEligibility: player.eligibility.rawValue,
                            teamName: team.teamName,
                            teamImage: team.logo,
                            teamSid: team.sid,
                            teamid: team.id,
                            blockdate: blockdate
                        )
                    }
                }
                return blockedPlayers
            }
    }

    // MARK: Get Team Coach
    func teamTrainer(req: Request) throws -> EventLoopFuture<Response> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing team ID")
        }

        return Team.find(teamID, on: req.db)
            .flatMapThrowing { team in
                guard let coach = team?.coach else {
                    throw Abort(.notFound, reason: "Coach not found for the given team")
                }
                return coach
            }
            .encodeResponse(for: req) // Ensures proper encoding of the response
    }
    
    func getLivescoreShort(req: Request) throws -> EventLoopFuture<[LeagueMatchesShort]> {
        return Match.query(on: req.db)
            .filter(\.$status ~~ [.first, .second, .halftime])
            .with(\.$season) { seasonQuery in
                seasonQuery.with(\.$league)
            }
            .all()
            .map { matches in
                var leagueMatchesDict = [String: LeagueMatchesShort]()
                
                for match in matches {
                    // Safely unwrap season, then league
                    guard let league = match.season?.league else { continue }
                    let leagueName = league.name ?? "Nicht Gennant"
                    
                    // Initialize the entry in leagueMatchesDict if needed
                    if leagueMatchesDict[leagueName] == nil {
                        leagueMatchesDict[leagueName] = LeagueMatchesShort(matches: [], league: leagueName)
                    }
                    
                    // Build our short match object
                    let short = PublicMatchShort(
                        id: match.id,
                        details: match.details,
                        homeBlanket: MiniBlankett(id: match.$homeTeam.id, logo: match.homeBlanket?.logo, name: match.homeBlanket?.name),
                        awayBlanket: MiniBlankett(id: match.$awayTeam.id, logo: match.awayBlanket?.logo, name: match.awayBlanket?.name),
                        score: match.score,
                        status: match.status,
                        firstHalfDate: match.firstHalfStartDate,
                        secondHalfDate: match.secondHalfStartDate
                    )
                    
                    leagueMatchesDict[leagueName]?.matches.append(short)
                }
                
                return Array(leagueMatchesDict.values)
            }
    }

    // Fetch league by code AND its current (primary) season`
    func fetchLeagueAndCurrentSeason(_ code: String, db: Database) -> EventLoopFuture<(League, Season)> {
        // 1) Get the league
        return League.query(on: db)
            .filter(\.$code == code)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League with code \(code) not found"))
            .flatMap { league in
                // 2) Get the season where primary == true
                league.$seasons
                    .query(on: db)
                    .filter(\.$primary == true) // Optional<Bool> field; Fluent handles this
                    .with(\.$matches)           // eager-load matches for later stats
                    .first()
                    .unwrap(or: Abort(.notFound, reason: "No primary season found for league \(code)"))
                    .map { season in (league, season) }
            }
    }

}

extension ClientController {
    // Map DB -> Public DTOs
    private func toPublicShort(_ m: Match) -> PublicMatchShort {
        PublicMatchShort(
            id: m.id,
            details: m.details,
            // Use team relation IDs; take logo/name from the blankets you already store
            homeBlanket: MiniBlankett(
                id: m.$homeTeam.id,
                logo: m.homeBlanket?.logo,
                name: m.homeBlanket?.name
            ),
            awayBlanket: MiniBlankett(
                id: m.$awayTeam.id,
                logo: m.awayBlanket?.logo,
                name: m.awayBlanket?.name
            ),
            score: m.score,
            status: m.status,
            firstHalfDate: m.firstHalfStartDate,
            secondHalfDate: m.secondHalfStartDate
        )
    }

    // All matches for a team in a specific season
    private func fetchTeamMatches(inSeason seasonID: UUID, teamID: UUID, db: Database) -> EventLoopFuture<[PublicMatchShort]> {
        Match.query(on: db)
            .filter(\.$season.$id == seasonID)
            .group(.or) { or in
                or.filter(\.$homeTeam.$id == teamID)
                  .filter(\.$awayTeam.$id == teamID)
            }
            .all()
            .map { $0.map(self.toPublicShort) }
    }

    // MARK: - Club Detail (season-grouped) – updated to use TeamStatsPair
    func fetchClub(req: Request) throws -> EventLoopFuture<ClubDetailResponse> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing team ID")
        }

        let teamFuture = fetchTeam(byID: teamID, db: req.db)
        let leagueFuture = teamFuture.flatMap { self.fetchLeagueForTeam($0, db: req.db) }

        let playersFuture = teamFuture
            .flatMap { self.fetchPlayers(for: $0, db: req.db) }
            .map { players in
                players.map { player in
                    MiniPlayer(
                        id: player.id,
                        sid: player.sid,
                        image: player.image,
                        team_oeid: player.team_oeid,
                        name: player.name,
                        number: player.number,
                        birthday: player.birthday,
                        nationality: player.nationality,
                        position: player.position,
                        eligibility: player.eligibility,
                        registerDate: player.registerDate,
                        status: player.status,
                        isCaptain: player.isCaptain,
                        bank: player.bank
                    )
                }
            }

        // UPDATED: use the pair-returning stats function
        let teamStatsFuture = teamFuture.flatMap { self.getTeamStatsPair(teamID: $0.id!, db: req.db) }

        // Build [PublicSeasonMatches] from the team's league seasons
        let seasonsFuture: EventLoopFuture<[PublicSeasonMatches]> = teamFuture.and(leagueFuture).flatMap { (team, league) in
            guard let league = league, let leagueID = league.id, let tID = team.id else {
                return req.eventLoop.makeSucceededFuture([])
            }

            return Season.query(on: req.db)
                .filter(\.$league.$id == leagueID)
                .all()
                .flatMap { seasons in
                    let perSeason: [EventLoopFuture<PublicSeasonMatches>] = seasons.compactMap { season in
                        guard let sID = season.id else { return nil }
                        return self.fetchTeamMatches(inSeason: sID, teamID: tID, db: req.db)
                            .map { matches in
                                PublicSeasonMatches(
                                    leagueName: league.name,
                                    leagueID: leagueID,
                                    seasonID: sID,
                                    seasonName: season.name,
                                    primary: season.primary ?? false,
                                    matches: matches
                                )
                            }
                    }
                    return perSeason.flatten(on: req.eventLoop)
                }
                .map { $0.sorted { ($0.primary && !$1.primary) } }
        }

        let newsFuture = teamFuture.and(leagueFuture).flatMap { (team, league) in
            self.fetchTeamAndLeagueNews(teamName: team.teamName, leagueCode: league?.code, db: req.db)
        }

        // Assemble response
        return teamFuture
            .and(leagueFuture)
            .and(playersFuture)
            .and(teamStatsFuture)    // <-- pair now
            .and(seasonsFuture)
            .and(newsFuture)
            .map { result in
                let (((((team, _league), players), teamStatsPair), seasons), news) = result

                let club = PublicTeamFull(
                    id: team.id,
                    sid: team.sid,
                    leagueCode: team.leagueCode,
                    points: team.points,
                    logo: team.logo,
                    coverimg: team.coverimg,
                    teamName: team.teamName,
                    foundationYear: team.foundationYear,
                    membershipSince: team.membershipSince,
                    averageAge: team.averageAge,
                    coach: team.coach,
                    captain: team.captain,
                    trikot: team.trikot,
                    players: players,
                    stats: teamStatsPair     // <-- pair assigned here
                )

                return ClubDetailResponse(
                    club: club,
                    upcoming: seasons,
                    news: news
                )
            }
    }
    
    // MARK: - Club Detail (for Backend on Team Section – players only)
    func teamSectionClub(req: Request) throws -> EventLoopFuture<PublicTeamFull> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing team ID")
        }

        let teamFuture = fetchTeam(byID: teamID, db: req.db)

        let playersFuture = teamFuture
            .flatMap { self.fetchPlayers(for: $0, db: req.db) }
            .map { players in
                players.map { player in
                    MiniPlayer(
                        id: player.id,
                        sid: player.sid,
                        image: player.image,
                        team_oeid: player.team_oeid,
                        name: player.name,
                        number: player.number,
                        birthday: player.birthday,
                        nationality: player.nationality,
                        position: player.position,
                        eligibility: player.eligibility,
                        registerDate: player.registerDate,
                        status: player.status,
                        isCaptain: player.isCaptain,
                        bank: player.bank
                    )
                }
            }

        // Only stats + players
        let teamStatsFuture = teamFuture.flatMap { self.getTeamStatsPair(teamID: $0.id!, db: req.db) }

        return teamFuture
            .and(playersFuture)
            .and(teamStatsFuture)
            .map { result in
                let ((team, players), teamStatsPair) = result

                return PublicTeamFull(
                    id: team.id,
                    sid: team.sid,
                    leagueCode: team.leagueCode,
                    points: team.points,
                    logo: team.logo,
                    coverimg: team.coverimg,
                    teamName: team.teamName,
                    foundationYear: team.foundationYear,
                    membershipSince: team.membershipSince,
                    averageAge: team.averageAge,
                    coach: team.coach,
                    captain: team.captain,
                    trikot: team.trikot,
                    players: players,
                    stats: teamStatsPair
                )
            }
    }
}


// MARK: - Tiny TTL cache (soft LRU-ish)
private actor _LRUCache<Value> {
    struct Entry { let value: Value; let expiresAt: Date }
    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval) { self.ttl = ttl }

    func get(_ key: String) -> Value? {
        guard let e = store[key] else { return nil }
        if e.expiresAt > Date() { return e.value }
        store[key] = nil
        return nil
    }

    func set(_ key: String, _ value: Value) {
        store[key] = .init(value: value, expiresAt: Date().addingTimeInterval(ttl))
        // very soft cap to avoid unbounded growth
        if store.count > 256, let first = store.keys.first {
            store.removeValue(forKey: first)
        }
    }
}

// Reuse caches across requests in this process
private enum Cache {
    // Cache the expensive (player, league) => [PublicSeasonMatches] assembly
    static let seasons = _LRUCache<[PublicSeasonMatches]>(ttl: 30) // seconds
}

// MARK: - Public DTOs you already use (shown for reference)
// struct PublicPlayer { ... }
// struct PublicSeasonMatches { let leagueName: String; let leagueID: UUID; let seasonID: UUID; let seasonName: String; let primary: Bool; let matches: [PublicMatchShort] }
// struct PlayerDetailResponse { let player: PublicPlayer; let upcoming: [PublicSeasonMatches]; let news: [PublicNews]? }

// MARK: - Helper (nil-safe date compare)
private func _date(_ match: Match) -> Date {
    match.details.date ?? .distantFuture
}

private func _containsPlayer(_ playerID: UUID, in match: Match) -> Bool {
    PlayerStatisticsService.contains(playerID, in: match)
}

private func _countsAsAppearance(_ match: Match) -> Bool {
    PlayerStatisticsService.countsAsAppearance(match)
}

private func _countsAsAppearance(_ match: PublicMatchShort) -> Bool {
    guard let status = match.status else { return false }
    switch status {
    case .pending, .cancelled:
        return false
    default:
        return true
    }
}

extension ClientController {
    // Build (and cache) the seasons+matches view for a given player within a league
    func seasonsForPlayerFast(
        player: Player,
        league: League,
        req: Request
    ) -> EventLoopFuture<[PublicSeasonMatches]> {
        guard let leagueID = league.id, let playerID = player.id else {
            return req.eventLoop.makeSucceededFuture([])
        }

        let cacheKey = "player:\(playerID.uuidString)|league:\(leagueID.uuidString)"
        if let cached = Caches.seasons.get(cacheKey) {
            return req.eventLoop.makeSucceededFuture(cached)
        }

        let homePlayerPath: [FieldKey] = ["homeBlanket", "players", "id"]
        let awayPlayerPath: [FieldKey] = ["awayBlanket", "players", "id"]
        let blanketMatchesF = Match.query(on: req.db)
            .group(.or) { group in
                group.filter(homePlayerPath, .equal, playerID)
                group.filter(awayPlayerPath, .equal, playerID)
            }
            .with(\.$season) { season in
                season.with(\.$league)
            }
            .all()

        // An event is also evidence that the player appeared. Keeping this
        // union makes old/incomplete match blankets visible instead of silently
        // dropping matches which already contain a goal or card for the player.
        let eventMatchesF = MatchEvent.query(on: req.db)
            .filter(\.$player.$id == playerID)
            .with(\.$match) { match in
                match.with(\.$season) { season in
                    season.with(\.$league)
                }
            }
            .all()
            .map { $0.map(\.match) }

        // Preserve the current league's active season even before the player has
        // an appearance in it, so the UI can show accurate zero season stats.
        let activeSeasonsF = Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$primary == true)
            .with(\.$league)
            .all()

        return blanketMatchesF.and(eventMatchesF).and(activeSeasonsF).map { result, activeSeasons in
            let (blanketMatches, eventMatches) = result
            var matchesByID = [UUID: Match]()
            for match in blanketMatches + eventMatches {
                if let matchID = match.id {
                    matchesByID[matchID] = match
                }
            }
            let relevant = Array(matchesByID.values)

            var matchesBySeason: [UUID: [Match]] = [:]
            var seasonsByID: [UUID: Season] = [:]

            for match in relevant {
                guard let season = match.season, let seasonID = season.id else { continue }
                matchesBySeason[seasonID, default: []].append(match)
                seasonsByID[seasonID] = season
            }
            for season in activeSeasons {
                if let seasonID = season.id {
                    seasonsByID[seasonID] = season
                }
            }

            let orderedSeasons = seasonsByID.values.sorted { lhs, rhs in
                let lhsPrimary = lhs.primary ?? false
                let rhsPrimary = rhs.primary ?? false
                if lhsPrimary != rhsPrimary { return lhsPrimary && !rhsPrimary }
                if lhs.details != rhs.details { return lhs.details > rhs.details }
                return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
            }

            let payload: [PublicSeasonMatches] = orderedSeasons.compactMap { season in
                guard
                    let seasonID = season.id,
                    let seasonLeagueID = season.$league.id
                else { return nil }

                let seasonLeagueName = season.league?.name ??
                    (seasonLeagueID == leagueID ? league.name : "Unbekannte Liga")
                let publicMatches = (matchesBySeason[seasonID] ?? [])
                    .sorted {
                        let d0 = $0.details.date ?? .distantFuture
                        let d1 = $1.details.date ?? .distantFuture
                        if d0 != d1 { return d0 < d1 }
                        return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                    }
                    .map(self.toPublicShort)

                return PublicSeasonMatches(
                    leagueName: seasonLeagueName,
                    leagueID: seasonLeagueID,
                    seasonID: seasonID,
                    seasonName: season.name,
                    primary: (season.primary ?? false) && seasonLeagueID == leagueID,
                    matches: publicMatches
                )
            }

            Caches.seasons.set(cacheKey, payload)
            return payload
        }
        .flatMapError { _ in
            // Player history is optional presentation data. A temporary
            // database problem should leave the profile usable.
            req.eventLoop.makeSucceededFuture([])
        }
    }

    // MARK: Player Detail (season-grouped + cached)
    func fetchPlayer(req: Request) throws -> EventLoopFuture<PlayerDetailResponse> {
        guard let playerID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing player ID")
        }

        // player (+team)
        let playerF: EventLoopFuture<Player> = Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Player not found"))
            .flatMap { player in
                player.$team.load(on: req.db).map { player }
            }

        // league via player's team (may be nil)
        let leagueF: EventLoopFuture<League?> = playerF.flatMap { player in
            guard let team = player.team else { return req.eventLoop.makeSucceededFuture(nil) }
            return self.fetchLeagueForTeam(team, db: req.db)
        }

        // seasons + matches (uses cache)
        let seasonsF: EventLoopFuture<[PublicSeasonMatches]> = playerF.and(leagueF).flatMap { (player, league) in
            guard let league = league else { return req.eventLoop.makeSucceededFuture([]) }
            return self.seasonsForPlayerFast(player: player, league: league, req: req)
        }

        // Stats use the exact same appearance list returned to the frontend.
        let statsF: EventLoopFuture<PlayerStatsPair> = seasonsF.and(leagueF).flatMap { seasons, league in
            self.getPlayerStatsBundle(
                playerID: playerID,
                activeLeagueID: league?.id,
                seasons: seasons,
                db: req.db
            )
        }

        return playerF.and(seasonsF).and(statsF).map { (playerAndSeasons, stats) in
            let (player, seasons) = playerAndSeasons

            let publicPlayer = PublicPlayer(
                id: player.id,
                sid: player.sid,
                image: player.image,
                team_oeid: player.team_oeid,
                name: player.name,
                number: player.number,
                birthday: player.birthday,
                team: player.team?.asPublicTeam(),
                nationality: player.nationality,
                position: player.position,
                eligibility: player.eligibility,
                registerDate: player.registerDate,
                status: player.status,
                isCaptain: player.isCaptain,
                bank: player.bank,
                allstats: stats.all,
                seasonstats: stats.season
            )

            return PlayerDetailResponse(
                player: publicPlayer,
                upcoming: seasons,
                news: nil
            )
        }
    }
}

extension ClientController {
    
    func getPlayerStatsBundle(
        playerID: UUID,
        activeLeagueID: UUID?,
        seasons _: [PublicSeasonMatches],
        db: Database
    ) -> EventLoopFuture<PlayerStatsPair> {
        PlayerStatisticsService.calculate(
            playerID: playerID,
            activeLeagueID: activeLeagueID,
            on: db
        )
    }

}


// MARK: LEADERBOARD
extension ClientController {
    
    func getGoalLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .goal)
    }

    func getRedCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .redCard)
    }

    func getYellowCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .yellowCard)
    }

    func getYellowRedCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .yellowRedCard)
    }

    private func getLeaderBoard(req: Request, eventType: MatchEventType) -> EventLoopFuture<[LeaderBoard]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }
        return LeaderboardService.fetch(
            leagueID: leagueID,
            eventType: eventType,
            primaryOnly: false,
            on: req.db
        )
    }

    // 3) Supply the team info
    private func mapEventsToLeaderBoard(
        _ events: [MatchEvent],
        playerTeamDict: [UUID: (String?, String?, String?)]
    ) -> [LeaderBoard] {
        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, count: Int)] = [:]

        for event in events {
            // OptionalParent -> id is UUID?
            guard let pid = event.$player.id else {
                // No player (or already deleted and set to null) → skip for leaderboard
                continue
            }

            let info = (event.name, event.image, event.number)

            if let existing = playerEventCounts[pid] {
                playerEventCounts[pid] = (
                    existing.name,
                    existing.image,
                    existing.number,
                    existing.count + 1
                )
            } else {
                playerEventCounts[pid] = (info.0, info.1, info.2, 1)
            }
        }

        return playerEventCounts
            .map { (playerId, data) in
                let (teamImg, teamName, teamId) = playerTeamDict[playerId] ?? (nil, nil, nil)

                return LeaderBoard(
                    name: data.name,
                    image: data.image,
                    number: data.number,
                    count: Double(data.count),
                    playerid: playerId,
                    teamimg: teamImg,
                    teamName: teamName,
                    teamId: teamId
                )
            }
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
    }


}

// MARK: LEADERBOARD (Primary Season only)
extension ClientController {

    // Public endpoints (season-only copies)
    func getGoalLeaderBoardSeason(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoardSeason(req: req, eventType: .goal)
    }

    func getRedCardLeaderBoardSeason(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoardSeason(req: req, eventType: .redCard)
    }

    func getYellowCardLeaderBoardSeason(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoardSeason(req: req, eventType: .yellowCard)
    }

    func getYellowRedCardLeaderBoardSeason(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoardSeason(req: req, eventType: .yellowRedCard)
    }

    // Private core (filters to league's primary season)
    private func getLeaderBoardSeason(req: Request, eventType: MatchEventType) -> EventLoopFuture<[LeaderBoard]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return LeaderboardService.fetch(
            leagueID: leagueID,
            eventType: eventType,
            primaryOnly: true,
            on: req.db
        )
    }
}

extension ClientController {
    /// GET /team/league/:id -> PublicLeagueOverview
    func fetchLeague(req: Request) throws -> EventLoopFuture<PublicLeagueOverview> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID")
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .map { league in
                PublicLeagueOverview(
                    id: league.id,
                    state: league.state,
                    code: league.code,
                    teamcount: league.teamcount,
                    name: league.name,
                    visibility: league.visibility
                )
            }
    }
}

// ClientController+TeamNextMatch.swift
extension ClientController {
    /// GET /team/:id/nextmatch -> PublicMatchShort
    func getTeamNextmatch(req: Request) throws -> EventLoopFuture<PublicMatchShort> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing team ID")
        }

        // Team -> League -> Primary Season
        let teamF = Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))

        let leagueF = teamF
            .flatMap { self.fetchLeagueForTeam($0, db: req.db) }
            .unwrap(or: Abort(.notFound, reason: "League for team not found"))

        let primarySeasonF = leagueF.flatMap { league in
            Season.query(on: req.db)
                .filter(\.$league.$id == league.id!)
                .filter(\.$primary == true)
                .first()
                .unwrap(or: Abort(.notFound, reason: "Primary season not found"))
        }

        // Matches for the team in the primary season, status == .pending
        return primarySeasonF.flatMap { season in
            Match.query(on: req.db)
                .filter(\.$season.$id == season.id!)
                .group(.or) { or in
                    or.filter(\.$homeTeam.$id == teamID)
                      .filter(\.$awayTeam.$id == teamID)
                }
                .filter(\.$status == .pending)
                .all()
                .flatMapThrowing { matches in
                    // Sort by gameday ascending and take the first pending match
                    let next = matches.sorted { lhs, rhs in
                        if lhs.details.gameday != rhs.details.gameday {
                            return lhs.details.gameday < rhs.details.gameday
                        }
                        // deterministic tiebreaker
                        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
                    }.first

                    guard let match = next else {
                        throw Abort(.notFound, reason: "No upcoming pending match found")
                    }
                    return self.toPublicShort(match)
                }
        }
    }
}
