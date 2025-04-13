import Vapor
import Fluent

final class HomepageController: RouteCollection {
    let path: String

    init(path: String) {
        self.path = path
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: path))

        route.get("leagueList", use: fetchLeagueList)
        route.get("byCode", ":code", "homepage", use: fetchHomepage)
        route.get(":id", "homepage", "livescore", use: fetchLivescore)
        route.get(":id", "homepage", "clubs", use: fetchLeagueClubs)
        route.get("homepage", "clubs", ":id", use: fetchClub)
        route.get("homepage", "clubs", "players", ":playerID", use: fetchPlayerDetail)
        route.get(":id", "homepage", "news", use: fetchLeagueNews)
        route.get("homepage", "news", ":newsItemID", use: fetchNewsItem)
        route.get("homepage", "season", ":seasonID", use: fetchNewsItem)

        route.get("homepage", ":id", "tabelle", use: getLeagueTable)
        route.get(":id", "homepage", "matches", use: fetchLeagueMatches)
        route.get("match", ":id", "details", use: fetchMatchDetail)

        route.get(":id", "homepage", "goalLeaderBoard", use: getGoalLeaderBoard)
        route.get(":id", "homepage", "redCardLeaderBoard", use: getRedCardLeaderBoard)
        route.get(":id","homepage", "yellowCardLeaderBoard", use: getYellowCardLeaderBoard)

        route.post("homepage", "register", use: register)
    }

    // MARK: - Homepage Data

    func fetchLeagueList(req: Request) throws -> EventLoopFuture<[PublicLeagueOverview]> {
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

    func fetchHomepage(req: Request) throws -> EventLoopFuture<PublicHomepageLeague> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league code")
        }

        return findLeague(byCode: leagueCode, db: req.db)
            .flatMap { league in
                // Start all async fetches
                let teamsFuture = self.fetchTeams(for: league, db: req.db)
                let newsFuture = self.fetchNewsItems(for: league, code: leagueCode, db: req.db)
                let seasonsFuture = self.fetchSeasonsWithMatches(for: league, db: req.db)

                return teamsFuture.and(newsFuture).and(seasonsFuture).flatMap { result in
                    let (teams, newsItems, seasons) = (result.0.0, result.0.1, result.1)

                    let upcomingMatches = self.getUpcomingMatches(from: seasons)
                    let publicTeams = self.mapTeamsToPublic(teams)
                    let upcomingMatchesShort = self.mapMatchesToShort(upcomingMatches)

                    return req.eventLoop.future(
                        PublicHomepageLeague(
                            data: league.homepagedata,
                            teams: publicTeams,
                            news: newsItems,
                            upcoming: upcomingMatchesShort
                        )
                    )
                }
            }
    }

    // MARK: - Helper Methods for fetchHomepage

    private func findLeague(byCode code: String, db: Database) -> EventLoopFuture<League> {
        return League.query(on: db)
            .filter(\League.$code == code)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
    }

    private func fetchTeams(for league: League, db: Database) -> EventLoopFuture<[Team]> {
        return league.$teams.query(on: db)
            .with(\.$players)
            .all()
    }

    private func fetchNewsItems(for league: League, code: String, db: Database) -> EventLoopFuture<[NewsItem]> {
        return NewsItem.query(on: db)
            .group(.or) { group in
                group.filter(\NewsItem.$tag == code)
                group.filter(\NewsItem.$tag == "Alle")
            }
            .all()
    }

    private func fetchSeasonsWithMatches(for league: League, db: Database) -> EventLoopFuture<[Season]> {
        return league.$seasons.query(on: db)
            .with(\.$matches) { match in
                match.with(\.$homeTeam)
                     .with(\.$awayTeam)
            }
            .all()
    }

    private func getUpcomingMatches(from seasons: [Season]) -> [Match] {
        let allMatches = seasons.flatMap { $0.matches }
        let now = Date.viennaNow
        guard let nextWeek = Calendar.current.date(byAdding: .day, value: 6, to: now) else { return [] }

        return allMatches.filter { match in
            guard let matchDate = match.details.date else { return false }
            return matchDate >= now && matchDate <= nextWeek
        }
    }

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

    // MARK: - Other Handlers

    func fetchLeagueClubs(req: Request) throws -> EventLoopFuture<[PublicTeamShort]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID")
        }
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                league.$teams.query(on: req.db)
                    .with(\.$players)
                    .all()
                    .map { teams in
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

    func fetchClub(req: Request) throws -> EventLoopFuture<PublicTeamFull> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing team ID")
        }
        return Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))
            .flatMap { team in
                team.$players.query(on: req.db).all().flatMap { players in
                    // Fetch stats for each player and the team
                    let playerStatsFutures = players.map { player in
                        self.getPlayerStats(playerID: player.id!, db: req.db).map { stats in
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

                    let teamStatsFuture = self.getTeamStats(teamID: team.id!, db: req.db)

                    return req.eventLoop.flatten(playerStatsFutures).and(teamStatsFuture).map { (publicPlayers, teamStats) in
                        PublicTeamFull(
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
                    }
                }
            }
    }

    func fetchLivescore(req: Request) throws -> EventLoopFuture<[PublicMatch]> {
        return Match.query(on: req.db)
            .filter(\.$status ~~ [.first, .second, .halftime])
            .with(\.$season) { seasonQuery in
                seasonQuery.with(\.$league)
            }
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$events)
            .all()
            .map { matches in
                matches.map { match in
                    PublicMatch(
                        id: match.id,
                        details: match.details,
                        referee: match.$referee.wrappedValue,
                        season: match.$season.wrappedValue,
                        homeBlanket: match.homeBlanket,
                        awayBlanket: match.awayBlanket,
                        events: match.events,
                        score: match.score,
                        status: match.status,
                        bericht: match.bericht,
                        firstHalfDate: match.firstHalfStartDate,
                        secondHalfDate: match.secondHalfStartDate
                    )
                }
            }
    }

    func fetchPlayerDetail(req: Request) throws -> EventLoopFuture<PublicPlayer> {
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing player ID")
        }
        return Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Player not found"))
            .flatMap { player in
                self.getPlayerStats(playerID: playerID, db: req.db).map { stats in
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
    }

    func fetchLeagueNews(req: Request) throws -> EventLoopFuture<[NewsItem]> {
        guard let leagueParam = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID or code")
        }

        return League.query(on: req.db)
            .group(.or) { group in
                if let leagueID = UUID(uuidString: leagueParam) {
                    group.filter(\.$id == leagueID)
                } else {
                    group.filter(\.$code == leagueParam)
                }
            }
            .first()
            .flatMap { optionalLeague in
                guard let league = optionalLeague else {
                    return req.eventLoop.future(error: Abort(.notFound, reason: "League not found"))
                }

                return NewsItem.query(on: req.db)
                    .group(.or) { group in
                        group.filter(\.$tag == "Alle")
                        if let code = league.code {
                            group.filter(\.$tag == code)
                        }
                        if let lID = league.id?.uuidString {
                            group.filter(\.$tag == lID)
                        }
                    }
                    .all()
            }
    }

    func fetchNewsItem(req: Request) throws -> EventLoopFuture<NewsItem> {
        guard let newsItemID = req.parameters.get("newsItemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing news item ID")
        }
        return NewsItem.find(newsItemID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "News item not found"))
    }

    func fetchMatchDetail(req: Request) throws -> EventLoopFuture<PublicMatch> {
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

    func register(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let registrationRequest = try req.content.decode(TeamRegistrationRequest.self)

        let newRegistration = TeamRegistration()
        newRegistration.primary = registrationRequest.primaryContact
        newRegistration.secondary = registrationRequest.secondaryContact
        newRegistration.teamName = registrationRequest.teamName
        newRegistration.verein = registrationRequest.verein
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.status = .draft
        newRegistration.paidAmount = 0.0
        newRegistration.bundesland = registrationRequest.bundesland
        newRegistration.initialPassword = registrationRequest.initialPassword ?? String.randomString(length: 8)
        newRegistration.isWelcomeEmailSent = true
        newRegistration.isLoginDataSent = false

        return newRegistration.save(on: req.db).map {
            self.sendWelcomeEmailInBackground(req: req, recipient: registrationRequest.primaryContact.email, registration: newRegistration)
            return HTTPStatus.ok
        }.flatMapError { _ in
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid request"))
        }
    }

    private func sendWelcomeEmailInBackground(req: Request, recipient: String, registration: TeamRegistration?) {
        req.eventLoop.execute {
            do {
                try emailController.sendWelcomeMail(req: req, recipient: recipient, registration: registration).whenComplete { result in
                    switch result {
                    case .success:
                        print("Welcome email sent successfully to \(recipient)")
                    case .failure(let error):
                        print("Failed to send welcome email to \(recipient): \(error)")
                    }
                }
            } catch {
                print("Failed to initiate sending welcome email to \(recipient): \(error)")
            }
        }
    }

    // MARK: - Leaderboard Handlers

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
                let playerIDs = teams.flatMap { $0.players.compactMap { $0.id } }

                return MatchEvent.query(on: req.db)
                    .filter(\.$player.$id ~~ playerIDs)
                    .filter(\.$type == eventType)
                    .all()
                    .map { events in
                        self.mapEventsToLeaderBoard(events)
                    }
            }
    }

    // MARK: - Stats & Utilities

    func getPlayerStats(playerID: UUID, db: Database) -> EventLoopFuture<PlayerStats> {
        return MatchEvent.query(on: db)
            .filter(\.$player.$id == playerID)
            .all()
            .map { events in
                var stats = PlayerStats(matchesPlayed: 0, goalsScored: 0, redCards: 0, yellowCards: 0, yellowRedCrd: 0)
                var matchSet = Set<UUID>()

                for event in events {
                    matchSet.insert(event.$match.id)
                    switch event.type {
                    case .goal:
                        stats.goalsScored += 1
                    case .redCard:
                        stats.redCards += 1
                    case .yellowCard:
                        stats.yellowCards += 1
                    case .yellowRedCard:
                        stats.yellowRedCrd += 1
                    default:
                        break
                    }
                }
                stats.matchesPlayed = matchSet.count
                return stats
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
                var stats = TeamStats(wins: 0, draws: 0, losses: 0, totalScored: 0, totalAgainst: 0, goalDifference: 0, totalPoints: 0, totalYellowCards: 0, totalRedCards: 0)

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
                        if let assign = event.assign {
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
                }
                stats.goalDifference = stats.totalScored - stats.totalAgainst
                return stats
            }
    }

    func getLeagueTable(req: Request) -> EventLoopFuture<[TableItem]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
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

    func fetchLeagueMatches(req: Request) throws -> EventLoopFuture<[PublicMatchShort]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID")
        }

        return Match.query(on: req.db)
            .join(Season.self, on: \Match.$season.$id == \Season.$id)
            .filter(Season.self, \Season.$league.$id == leagueID)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
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

    private func mapEventsToLeaderBoard(_ events: [MatchEvent]) -> [LeaderBoard] {
        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, id: UUID, count: Int)] = [:]

        for event in events {
            let playerId = event.$player.id
            let playerInfo = (event.name, event.image, event.number)

            if var existing = playerEventCounts[playerId] {
                existing.count += 1
                playerEventCounts[playerId] = existing
            } else {
                playerEventCounts[playerId] = (playerInfo.0, playerInfo.1, playerInfo.2, playerId, 1)
            }
        }

        let leaderboard = playerEventCounts.map { (_, playerData) in
            LeaderBoard(
                name: playerData.name,
                image: playerData.image,
                number: playerData.number,
                count: playerData.count.asDouble(),
                playerid: playerData.id,
                teamimg: nil,
                teamName: nil,
                teamId: nil
            )
        }

        return leaderboard
    }

}


// MARK: - Supporting Models

struct PublicLeagueOverview: Content, Codable {
    var id: UUID?
    var state: Bundesland?
    var code: String?
    var teamcount: Int?
    var name: String
}

struct PublicHomepageLeague: Content, Codable {
    var data: HomepageData?
    var teams: [PublicTeamShort]?
    var news: [NewsItem]?
    var upcoming: [PublicMatchShort]?
}

struct PublicTeam: Content, Codable {
    var id: UUID?
    var sid: String?
    var leagueCode: String?
    var points: Int
    var logo: String
    var coverimg: String?
    var teamName: String
    var foundationYear: String?
    var membershipSince: String?
    var averageAge: String
    var coach: Trainer?
    var captain: String?
    var trikot: Trikot
    var stats: TeamStats?
}

struct PublicTeamShort: Content, Codable {
    var id: UUID?
    var sid: String?
    var logo: String
    var teamName: String
}


struct PublicTeamFull: Content, Codable {
    var id: UUID?
    var sid: String?
    var leagueCode: String?
    var points: Int
    var logo: String
    var coverimg: String?
    var teamName: String
    var foundationYear: String?
    var membershipSince: String?
    var averageAge: String
    var coach: Trainer?
    var captain: String?
    var trikot: Trikot
    var players: [MiniPlayer]
    var stats: TeamStats?
}

struct MiniPlayer: Content, Codable {
    var id: UUID?
    var sid: String
    var image: String?
    var team_oeid: String?
    var name: String
    var number: String
    var birthday: String
    var nationality: String
    var position: String
    var eligibility: PlayerEligibility
    var registerDate: String
    var status: Bool?
    var isCaptain: Bool?
    var bank: Bool?
}


struct PublicPlayer: Content, Codable {
    var id: UUID?
    var sid: String
    var image: String?
    var team_oeid: String?
    var name: String
    var number: String
    var birthday: String
    var team: PublicTeam?
    var nationality: String
    var position: String
    var eligibility: PlayerEligibility
    var registerDate: String
    var status: Bool?
    var isCaptain: Bool?
    var bank: Bool?
    var stats: PlayerStats?
}


struct PublicClubPage: Content, Codable {
    let club: PublicTeam
    let fixtures: [PublicMatch]
}

struct PublicMatch: Content, Codable {
    var id: UUID?
    var details: MatchDetails
    var referee: Referee?
    var season: Season?
    var homeBlanket: Blankett?
    var awayBlanket: Blankett?
    var events: [MatchEvent]
    var score: Score
    var status: GameStatus
    var bericht: String?
    var firstHalfDate: Date?
    var secondHalfDate: Date?
}

struct PublicMatchShort: Content, Codable {
    var id: UUID?
    let details: MatchDetails?
    var homeBlanket: MiniBlankett?
    var awayBlanket: MiniBlankett?
    var score: Score?
    var status: GameStatus?
    var firstHalfDate: Date?
    var secondHalfDate: Date?
}

struct MiniBlankett: Codable {
    let id: UUID?
    let logo: String?
    let name: String?
}

struct PlayerStats: Content, Codable {
    var matchesPlayed: Int
    var goalsScored: Int
    var redCards: Int
    var yellowCards: Int
    var yellowRedCrd: Int
}
