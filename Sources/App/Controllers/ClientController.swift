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
        let playersFuture = teamFuture.flatMap { self.fetchPlayers(for: $0, db: req.db) }
        let playerStatsFuture = playersFuture.flatMap { self.fetchAllPlayerStats($0, db: req.db) }
        let teamStatsFuture = teamFuture.flatMap { self.getTeamStats(teamID: $0.id!, db: req.db) }
        let upcomingMatchesFuture = teamFuture.flatMap { self.getAllMatchesForTeam(teamID: $0.id!, db: req.db) }
        let newsFuture = teamFuture.and(leagueFuture).flatMap { (team, league) in
            self.fetchTeamAndLeagueNews(teamName: team.teamName, leagueCode: league?.code, db: req.db)
        }
        
        return teamFuture
            .and(leagueFuture)
            .and(playersFuture)
            .and(playerStatsFuture)
            .and(teamStatsFuture)
            .and(upcomingMatchesFuture)
            .and(newsFuture)
            .map { result in
                let ((((((team, league), players), publicPlayers), teamStats), upcomingMatches), news) = result
                
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
                    players: publicPlayers,
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
        
        // Query to fetch players with blockdate not nil and in the specified league
        return League.query(on: req.db)
            .filter(\.$code == leagueCode) // Filter leagues by code
            .with(\.$teams) { team in
                team.with(\.$players) // Fetch all players associated with the teams in the league
            }
            .first()
            .flatMapThrowing { league in
                guard let teams = league?.teams else { return [] }
                
                // Collect all players with a non-nil blockdate
                let blockedPlayers = teams.flatMap { team in
                    team.players.compactMap { player -> SperrItem? in
                        guard let blockdate = player.blockdate else { return nil }
                        return SperrItem(
                            playerName: player.name,
                            playerImage: player.image,
                            playerSid: player.sid,
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

// MARK: - Helper Fetch Methods (DB Calls)
extension ClientController {
    func fetchLeagueByCode(_ code: String, db: Database) -> EventLoopFuture<League> {
        League.query(on: db)
            .filter(\.$code == code)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
    }

    func fetchTeams(for league: League, db: Database) -> EventLoopFuture<[Team]> {
        league.$teams.query(on: db)
            .with(\.$players)
            .all()
    }

    func fetchLeagueNews(league: League, code: String, db: Database) -> EventLoopFuture<[NewsItem]> {
        NewsItem.query(on: db)
            .group(.or) { group in
                group.filter(\NewsItem.$tag == code)
                group.filter(\NewsItem.$tag == "Alle")
            }
            .all()
    }

    func fetchSeasons(for league: League, db: Database) -> EventLoopFuture<[Season]> {
        league.$seasons.query(on: db)
            .with(\.$matches) { match in
                match.with(\.$homeTeam)
                     .with(\.$awayTeam)
            }
            .all()
    }

    func fetchTeam(byID teamID: UUID, db: Database) -> EventLoopFuture<Team> {
        Team.find(teamID, on: db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))
    }

    func fetchLeagueForTeam(_ team: Team, db: Database) -> EventLoopFuture<League?> {
        team.$league.get(on: db)
    }

    func fetchPlayers(for team: Team, db: Database) -> EventLoopFuture<[Player]> {
        team.$players.query(on: db).all()
    }

    func fetchAllPlayerStats(_ players: [Player], db: Database) -> EventLoopFuture<[PublicPlayer]> {
        let futures = players.map { player in
            self.getPlayerStats(playerID: player.id!, db: db).map { stats in
                PublicPlayer(
                    id: player.id,
                    sid: player.sid,
                    image: player.image,
                    team_oeid: player.team_oeid,
                    name: player.name,
                    number: player.number,
                    birthday: player.birthday,
                    team: nil,
                    nationality: player.nationality,
                    position: player.position,
                    eligibility: player.eligibility,
                    registerDate: player.registerDate,
                    status: player.status,
                    isCaptain: player.isCaptain,
                    bank: player.bank,
                    stats: stats
                )
            }
        }
        return db.eventLoop.flatten(futures)
    }

    func fetchTeamAndLeagueNews(teamName: String, leagueCode: String?, db: Database) -> EventLoopFuture<[NewsItem]> {
        let teamNewsFuture = fetchRelatedNewsItems(term: leagueCode ?? "", db: db)
        let leagueNewsFuture = (leagueCode ?? "").isEmpty ? db.eventLoop.future([]) : fetchRelatedNewsItems(term: leagueCode!, db: db)
        return teamNewsFuture.and(leagueNewsFuture).map { teamNews, leagueNews in
            teamNews + leagueNews
        }
    }

    func fetchRelatedNewsItems(term: String, db: Database) -> EventLoopFuture<[NewsItem]> {
        NewsItem.query(on: db)
            .group(.or) { group in
                group.filter(\NewsItem.$tag == term)
                group.filter(\NewsItem.$tag == "Alle")
            }
            .all()
    }
}

// MARK: - Stats & Matches Utilities
extension ClientController {
    func getPlayerStats(playerID: UUID, db: Database) -> EventLoopFuture<PlayerStats> {
        
        // 1) All match events for this player (to count goal/card types)
                let eventsFuture = MatchEvent.query(on: db)
                    .filter(\.$player.$id == playerID)
                    .all()
                
                // 2) All matches where the player appears in either homeBlanket or awayBlanket
                let matchesFuture = Match.query(on: db)
                    .all()
                    .map { matches in
                        matches.filter { match in
                            let homeContains = match.homeBlanket?.players.contains { $0.id == playerID } ?? false
                            let awayContains = match.awayBlanket?.players.contains { $0.id == playerID } ?? false
                            return homeContains || awayContains
                        }
                    }
                
                // Combine the two and calculate the summary
                return eventsFuture.and(matchesFuture).map { (events, relevantMatches) in
                    let goalCount = events.filter { $0.type == .goal }.count
                    let redCardCount = events.filter { $0.type == .redCard }.count
                    let yellowCardCount = events.filter { $0.type == .yellowCard }.count
                    let yellowRedCardCount = events.filter { $0.type == .yellowRedCard }.count
                    
                    // Both totalAppearances and totalMatches come from the
                    // blanket-based match count as requested:
                    let totalMatches = relevantMatches.count
                    let totalAppearances = relevantMatches.count
                    
                    return PlayerStats(matchesPlayed: totalMatches,
                                           goalsScored: goalCount,
                                           redCards: redCardCount,
                                           yellowCards: yellowCardCount,
                                           yellowRedCrd: yellowRedCardCount)
                    }
            }

    func getTeamStats(teamID: UUID, db: Database) -> EventLoopFuture<TeamStats> {
        let validStatuses: [GameStatus] = [.completed, .abbgebrochen, .submitted, .cancelled, .done]

        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                group.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status ~~ validStatuses)
            .with(\.$events)
            .all()
            .map { matches in
                var stats = TeamStats(
                    wins: 0,
                    draws: 0,
                    losses: 0,
                    totalScored: 0,
                    totalAgainst: 0,
                    goalDifference: 0,
                    totalPoints: 0,
                    totalYellowCards: 0,
                    totalRedCards: 0
                )

                for match in matches {
                    let isHome = match.$homeTeam.id == teamID
                    let scored = isHome ? match.score.home : match.score.away
                    let against = isHome ? match.score.away : match.score.home
                    stats.totalScored += scored
                    stats.totalAgainst += against

                    if scored > against {
                        stats.wins += 1
                        stats.totalPoints += 3
                    } else if scored == against {
                        stats.draws += 1
                        stats.totalPoints += 1
                    } else {
                        stats.losses += 1
                    }

                    for event in match.events {
                        // Infer assign if it is nil
                        let inferredAssign: MatchAssignment = (event.$player.id == match.$homeTeam.id) ? .home : .away

                        // Use the inferred assign if `event.assign` is nil
                        let assign = event.assign ?? inferredAssign

                        // Update yellow/red card stats based on assign
                        if (isHome && assign == .home) || (!isHome && assign == .away) {
                            switch event.type {
                            case .yellowCard:
                                stats.totalYellowCards += 1
                            case .redCard:
                                stats.totalRedCards += 1
                            default:
                                break
                            }
                        }
                    }
                }
                stats.goalDifference = stats.totalScored - stats.totalAgainst
                return stats
            }
    }

    /// Returns all matches for a given team (home or away) as PublicMatchShort
    func getAllMatchesForTeam(teamID: UUID, db: Database) -> EventLoopFuture<[PublicMatchShort]> {
        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                group.filter(\.$awayTeam.$id == teamID)
            }
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$events)
            .all()
            .map { matches in
                matches.map { match in
                    PublicMatchShort(
                        id: match.id,
                        details: match.details,
                        homeBlanket: MiniBlankett(
                            id: match.$homeTeam.id,
                            logo: match.homeBlanket?.logo,
                            name: match.homeBlanket?.name
                        ),
                        awayBlanket: MiniBlankett(
                            id: match.$awayTeam.id,
                            logo: match.awayBlanket?.logo,
                            name: match.awayBlanket?.name
                        ),
                        score: match.score,
                        status: match.status
                    )
                }
            }
    }

    // MARK: Upcoming Matches Helper
    private func getUpcomingMatchesWithinNext7Days(from seasons: [Season]) -> [Match] {
        let allMatches = seasons.flatMap { $0.matches }
        let now = Date()
        guard let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return [] }

        return allMatches.filter { match in
            guard let matchDate = match.details.date else { return false }
            return matchDate >= now && matchDate <= nextWeek
        }
    }

    // MARK: Helper Mapping
    private func mapTeamsToPublic(_ teams: [Team]) -> [PublicTeamShort] {
        return teams.map { team in
            PublicTeamShort(
                id: team.id,
                sid: team.sid,
                logo: team.logo,
                teamName: team.teamName
            )
        }
    }

    private func mapMatchesToShort(_ matches: [Match]) -> [PublicMatchShort] {
        return matches.map { match in
            PublicMatchShort(
                id: match.id,
                details: match.details,
                homeBlanket: MiniBlankett(
                    id: match.$homeTeam.id,
                    logo: match.homeBlanket?.logo,
                    name: match.homeBlanket?.name
                ),
                awayBlanket: MiniBlankett(
                    id: match.$awayTeam.id,
                    logo: match.awayBlanket?.logo,
                    name: match.awayBlanket?.name
                ),
                score: match.score,
                status: match.status
            )
        }
    }

}

// MARK: - Response Structures
struct HomepageResponse: Codable, Content {
    var data: HomepageData?
    var teams: [PublicTeamShort]?
    var news: [NewsItem]?
    var upcoming: [PublicMatchShort]?
    let league: League?
}

struct ClubDetailResponse: Codable, Content {
    let club: PublicTeamFull
    var upcoming: [PublicMatchShort]?
    var news: [NewsItem]?
}

struct PlayerDetailResponse: Codable, Content {
    let player: PublicPlayer
    var upcoming: [PublicMatchShort]?
    var news: [NewsItem]?
}

struct TableResponse: Codable, Content {}
struct NewsResponse: Codable, Content {}
struct NewsDetailResponse: Codable, Content {}

struct RegistrationRequest: Codable, Content {}

// Define a structure to represent the match events publicly:
struct MatchEventOutput: Content, Codable {
    var id: UUID?
    var type: MatchEventType
    var minute: Int
    var name: String?
    var image: String?
    var number: String?
    var assign: MatchAssignment?
    var ownGoal: Bool?

    // Player info from the event
    var playerID: UUID?
    var playerName: String?
    var playerNumber: Int?
    var playerImage: String?
    var playerSid: String?
}

struct SperrItem: Codable, Content {
    let playerName: String?
    let playerImage: String?
    let playerSid: String?
    let teamName: String?
    let teamImage: String?
    let teamSid: String?
    let blockdate: Date?
}
