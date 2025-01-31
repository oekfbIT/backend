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
        route.get("table", "league", ":code", use: fetchtable)
        route.get("news", "league", ":code", use: fetchNews)
        route.get("transfers", use: fetchTransfers)
        route.get("news", "detail", ":id", use: fetchNewsItem)
        route.get("matches", "league", ":code", use: fetchFirstSeasonMatches)
        // First, define a route that fetches a single match by its ID and includes the events:
        route.get("match", "detail", ":id", use: fetchMatch)
        route.get("player", "detail", ":id", use: fetchPlayer)
        
        route.get("leaderboard", ":id", "goal", use: getGoalLeaderBoard)
        route.get("leaderboard", ":id", "redCard", use: getRedCardLeaderBoard)
        route.get("leaderboard",":id", "yellowCard", use: getYellowCardLeaderBoard)
        route.get("blocked", "league", ":code", use: blockedPlayers)

    }
    
    // MARK: League Selection
    func fetchLeagueSelection(req: Request) throws -> EventLoopFuture<[PublicLeagueOverview]> {
        return League.query(on: req.db).all().mapEach { league in
            PublicLeagueOverview(
                id: league.id,
                state: league.state,
                code: league.code,
                teamcount: league.teamcount,
                name: league.name
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
                        teamName: team.teamName
                    )
                }
            }
        }
    }
    
    // MARK: Club Detail
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
        let teamStatsFuture = teamFuture.flatMap { self.getTeamStats(teamID: $0.id!, db: req.db) }
        let upcomingMatchesFuture = teamFuture.flatMap { self.getAllMatchesForTeam(teamID: $0.id!, db: req.db) }
        let newsFuture = teamFuture.and(leagueFuture).flatMap { (team, league) in
            self.fetchTeamAndLeagueNews(teamName: team.teamName, leagueCode: league?.code, db: req.db)
        }

        return teamFuture
            .and(leagueFuture)
            .and(playersFuture)
            .and(teamStatsFuture)
            .and(upcomingMatchesFuture)
            .and(newsFuture)
            .map { result in
                let (((((team, league), players), teamStats), upcomingMatches), news) = result
                
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
                    players: players, // Mapped MiniPlayer array
                    stats: teamStats
                )
                
                return ClubDetailResponse(
                    club: club,
                    upcoming: upcomingMatches,
                    news: news
                )
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
                            difference: stats.goalDifference
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

    // MARK: MAtch Detail
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
                                bericht: match.bericht
                            )
                        }
                }
            }
    }

    // MARK: Player Detail
    func fetchPlayer(req: Request) throws -> EventLoopFuture<PlayerDetailResponse> {
        guard let playerID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing player ID")
        }

        // Fetch player with team
        let playerFuture: EventLoopFuture<Player> = Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Player not found"))
            .flatMap { player in
                player.$team.load(on: req.db).map { player } // Ensure player's team is loaded
            }

        // Fetch upcoming matches based on player's team
        let upcomingMatchesFuture: EventLoopFuture<[PublicMatchShort]> = playerFuture.flatMap { player in
            guard let teamID = player.$team.id else {
                return req.eventLoop.future([]) // No team ID -> return empty list
            }
            return self.getAllMatchesForTeam(teamID: teamID, db: req.db)
        }

        // Fetch player statistics
        let playerStatsFuture: EventLoopFuture<PlayerStats> = self.getPlayerStats(playerID: playerID, db: req.db)

        // Combine player details, stats, and upcoming matches
        return playerFuture.and(upcomingMatchesFuture).and(playerStatsFuture).map { (playerAndMatches, stats) in
            let (player, upcomingMatches) = playerAndMatches

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
                stats: stats // Include stats fetched from getPlayerStats
            )

            return PlayerDetailResponse(
                player: publicPlayer,
                upcoming: upcomingMatches,
                news: nil // Placeholder for news if needed
            )
        }
    }

    
    // MARK: LEADERBOARD
    func getGoalLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .goal)
    }

    func getRedCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .redCard)
    }

    func getYellowCardLeaderBoard(req: Request) -> EventLoopFuture<[LeaderBoard]> {
        return getLeaderBoard(req: req, eventType: .yellowCard)
    }

    private func getLeaderBoard(req: Request, eventType: MatchEventType) -> EventLoopFuture<[LeaderBoard]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return Team.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$players)
            .all()
            .flatMap { teams in
                // Build PlayerID -> (teamLogo, teamName, teamId)
                var playerTeamDict: [UUID: (String?, String?, String?)] = [:]
                for team in teams {
                    let tIDString = team.id?.uuidString
                    for player in team.players {
                        if let pid = player.id {
                            playerTeamDict[pid] = (team.logo, team.teamName, tIDString)
                        }
                    }
                }
                
                let playerIDs = playerTeamDict.keys.map { $0 }
                return MatchEvent.query(on: req.db)
                    .filter(\.$player.$id ~~ playerIDs)
                    .filter(\.$type == eventType)
                    .all()
                    .map { events in
                        self.mapEventsToLeaderBoard(events, playerTeamDict: playerTeamDict)
                    }
            }
    }

    // 3) Supply the team info
    private func mapEventsToLeaderBoard(
        _ events: [MatchEvent],
        playerTeamDict: [UUID: (String?, String?, String?)]
    ) -> [LeaderBoard] {
        
        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, count: Int)] = [:]
        
        for event in events {
            let pid = event.$player.id
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

        return playerEventCounts.compactMap { (playerId, data) in
            let (teamImg, teamName, teamId) = playerTeamDict[playerId] ?? (nil, nil, nil)
            
            return LeaderBoard(
                name: data.name,
                image: data.image,
                number: data.number,
                count: Double(data.count),
                teamimg: teamImg,
                teamName: teamName,
                teamId: teamId
            )
        }
        .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
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
                
                let currentDate = Date() // Get the current date

                // Collect all players that meet the conditions
                let blockedPlayers = teams.flatMap { team in
                    team.players.compactMap { player -> SperrItem? in
                        guard let blockdate = player.blockdate, blockdate > currentDate else { return nil }
                        guard player.eligibility == .Gesperrt else { return nil }
                        
                        return SperrItem(
                            playerName: player.name,
                            playerImage: player.image,
                            playerSid: player.sid,
                            playerEligibility: player.eligibility.rawValue,
                            teamName: team.teamName,
                            teamImage: team.logo,
                            teamSid: team.sid,
                            blockdate: blockdate
                        )
                    }
                }
                return blockedPlayers
            }
    }


}
