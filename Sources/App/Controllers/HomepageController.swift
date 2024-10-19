//
//  HomepageController.swift
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Vapor
import Fluent

final class HomepageController: RouteCollection {
    
    let path: String
    
    init(path: String) {
        self.path = path
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: path))
        
        route.get("leagueList", use: fetchLeagueList) // CHECK
        route.get(":id", "homepage", use: fetchHomepage) // CHECK
        route.get(":id", "homepage", "livescore", use: fetchLivescore) // League ID Parameter
        route.get(":id", "homepage", "clubs", use: fetchLeagueClubs) // League ID Parameter
        route.get("homepage", "clubs", ":id", use: fetchClub) // Team ID Parameter
        route.get("homepage", "clubs", "players", ":playerID", use: fetchPlayerDetail) // PlayerID parameter
        route.get(":id", "homepage", "news", use: fetchLeagueNews) // League ID Parameter
        route.get("homepage", "news", ":newsItemID", use: fetchNewsItem) // News Item ID Parameter
        
        
        route.get(":id", "homepage", "goalLeaderBoard", use: getGoalLeaderBoard) // LeagueID
        route.get(":id", "homepage", "redCardLeaderBoard", use: getRedCardLeaderBoard) // LeagueID
        route.get(":id","homepage", "yellowCardLeaderBoard", use: getYellowCardLeaderBoard)// LeagueID

        // Commented out due to missing implementations
         route.post("homepage", "register", use: register)
        // route.grouped(User.authenticator()).post("login", use: login)
    }
    
    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    // HOMEPAGE GETTERS

    func fetchLeagueList(req: Request) throws -> EventLoopFuture<[PublicLeagueOverview]> {
        // Get all the leagues and map them to PublicLeagueOverview
        return League.query(on: req.db).all().mapEach { league in
            return PublicLeagueOverview(
                id: league.id,
                state: league.state,
                code: league.code,
                teamcount: league.teamcount,
                name: league.name
            )
        }
    }
    
    func fetchHomepage(req: Request) throws -> EventLoopFuture<PublicHomepageLeague> {
        // Get the league from the League ID with the teams
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID")
        }
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                // Fetch teams with players
                return league.$teams.query(on: req.db)
                    .with(\.$players)
                    .all()
                    .flatMap { teams in
                        // Parse Teams into PublicTeams
                        let publicTeams = teams.map { team in
                            PublicTeam(
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
                                stats: nil
                            )
                        }
                        // Get all the news with the tag == leagueID as string
                        return NewsItem.query(on: req.db)
                            .filter(\.$tag == leagueID.uuidString)
                            .all()
                            .map { newsItems in
                                // Wrap into PublicHomepageLeague and return
                                PublicHomepageLeague(
                                    hero: league.hero,
                                    teams: publicTeams,
                                    news: newsItems
                                )
                            }
                    }
            }
    }
    
    func fetchLeagueClubs(req: Request) throws -> EventLoopFuture<[PublicTeam]> {
        // Get the league from the League ID with the teams
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID")
        }
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                return league.$teams.query(on: req.db)
                    .with(\.$players)
                    .all()
                    .map { teams in
                        // Parse the teams into PublicTeam
                        teams.map { team in
                            PublicTeam(
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
                                stats: nil
                            )
                        }
                    }
            }
    }
    
    func fetchClub(req: Request) throws -> EventLoopFuture<PublicTeamFull> {
        // Get the club (team) from the Team ID and parse into PublicTeam
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing team ID")
        }
        return Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Team not found"))
            .flatMap { team in
                return team.$players.query(on: req.db)
                    .all()
                    .map { players in
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
                            players: players.map { player in
                                PublicPlayer(
                                    id: player.id,
                                    sid: player.sid,
                                    image: player.image,
                                    team_oeid: player.team_oeid,
                                    name: player.name,
                                    number: player.number,
                                    birthday: player.birthday,
                                    team: nil, // Optionally include team if needed
                                    nationality: player.nationality,
                                    position: player.position,
                                    eligibility: player.eligibility,
                                    registerDate: player.registerDate,
                                    status: player.status,
                                    isCaptain: player.isCaptain,
                                    bank: player.bank,
                                    stats: default_player_stats // Stats can be calculated separately if needed
                                )
                            },
                            stats: default_team_stats
                        )
                    }
            }
    }

    func fetchLeagueNews(req: Request) throws -> EventLoopFuture<[NewsItem]> {
        // Search all the news items and get all where tag == leagueID parameter
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing league ID")
        }
        return NewsItem.query(on: req.db)
            .filter(\.$tag == leagueID.uuidString)
            .all()
    }
        
    func fetchNewsItem(req: Request) throws -> EventLoopFuture<NewsItem> {
        // Search the news item with the ID and return the item
        guard let newsItemID = req.parameters.get("newsItemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing news item ID")
        }
        return NewsItem.find(newsItemID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "News item not found"))
    }
    
    func fetchLivescore(req: Request) throws -> EventLoopFuture<[PublicMatch]> {
        return Match.query(on: req.db)
            .filter(\.$status ~~ [.first, .second, .halftime])  // Filter matches that are in progress
            .with(\.$season) { seasonQuery in
                seasonQuery.with(\.$league)  // Load the league through the season
            }
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$events)
            .all()  // Ensure we're fetching all matches
            .map { matches in
                // Parse them into [PublicMatch]
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
                        bericht: match.bericht
                    )
                }
            }
    }

    func fetchMatchDetail(req: Request) throws -> EventLoopFuture<PublicMatch> {
        // Get the match from the matchID and parse it into PublicMatch
        guard let matchID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing match ID")
        }
        return Match.find(matchID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Match not found"))
            .flatMap { match in
                // Ensure related data is loaded
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

    func fetchPlayerDetail(req: Request) throws -> EventLoopFuture<PublicPlayer> {
        // Get the player from the playerID and parse it into PublicPlayer
        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid or missing player ID")
        }
        return Player.find(playerID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Player not found"))
            .map { player in
                // Map Player to PublicPlayer
                PublicPlayer(
                    id: player.id,
                    sid: player.sid,
                    image: player.image,
                    team_oeid: player.team_oeid,
                    name: player.name,
                    number: player.number,
                    birthday: player.birthday,
                    team: nil, // Optionally include team if needed
                    nationality: player.nationality,
                    position: player.position,
                    eligibility: player.eligibility,
                    registerDate: player.registerDate,
                    status: player.status,
                    isCaptain: player.isCaptain,
                    bank: player.bank,
                    stats: default_player_stats // Stats can be calculated separately if needed
                )
            }
    }

    func register(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let registrationRequest = try req.content.decode(TeamRegistrationRequest.self)

        print(registrationRequest)
        
        let newRegistration = TeamRegistration()
        newRegistration.primary = registrationRequest.primaryContact
        newRegistration.secondary = registrationRequest.secondaryContact
        newRegistration.teamName = registrationRequest.teamName
        newRegistration.verein = registrationRequest.verein
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.status = .draft
        newRegistration.paidAmount = nil
        newRegistration.bundesland = registrationRequest.bundesland
        newRegistration.initialPassword = registrationRequest.initialPassword ?? String.randomString(length: 8)
        newRegistration.refereerLink = registrationRequest.referCode
        newRegistration.customerSignedContract = nil
        newRegistration.adminSignedContract = nil
        newRegistration.paidAmount = 0.0
        newRegistration.isWelcomeEmailSent = true
        newRegistration.isLoginDataSent = false
        
        return newRegistration.save(on: req.db).map { _ in
            // Send the welcome email in the background
            print("Created: ", newRegistration)
            self.sendWelcomeEmailInBackground(req: req, recipient: registrationRequest.primaryContact.email, registration: newRegistration)
            return HTTPStatus.ok
        }.flatMapError { error in
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid request"))
        }
    }

    // Background email sending function
    private func sendWelcomeEmailInBackground(req: Request, recipient: String, registration: TeamRegistration?) {
        // Run the email sending on the request's event loop
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

    // Generalized function for all leaderboards
    private func getLeaderBoard(req: Request, eventType: MatchEventType) -> EventLoopFuture<[LeaderBoard]> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        // Fetch teams and their players from the specified league
        return Team.query(on: req.db)
            .filter(\.$league.$id == leagueID) // Filter by the provided league ID
            .with(\.$players) // Load related players
            .all()
            .flatMap { teams in
                // Collect all player IDs from the league's teams
                let playerIDs = teams.flatMap { $0.players.compactMap { $0.id } }

                // Fetch all match events for these players
                return MatchEvent.query(on: req.db)
                    .filter(\.$player.$id ~~ playerIDs) // Only include events for players from the league
                    .filter(\.$type == eventType) // Filter by event type (goal, red card, yellow card)
                    .all()
                    .flatMap { events in
                        // Create a dictionary to count events per player
                        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, count: Int)] = [:]

                        for event in events {
                            let playerId = event.$player.id
                            let playerInfo = (event.name, event.image, event.number)
                            
                            if let existingCount = playerEventCounts[playerId]?.count {
                                playerEventCounts[playerId]?.count = existingCount + 1
                            } else {
                                playerEventCounts[playerId] = (playerInfo.0, playerInfo.1, playerInfo.2, 1)
                            }
                        }

                        // Convert the dictionary into a sorted array of LeaderBoard items
                        let leaderboard = playerEventCounts.map { (playerId, playerData) in
                            LeaderBoard(
                                name: playerData.name,
                                image: playerData.image,
                                number: playerData.number,
                                count: playerData.count
                            )
                        }.sorted { $0.count > $1.count }

                        return req.eventLoop.makeSucceededFuture(leaderboard)
                    }
            }
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
    var hero: Hero?
    var teams: [PublicTeam]?
    var news: [NewsItem]?
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
    var players: [PublicPlayer]
    var stats: TeamStats?
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

let default_player_stats = PlayerStats(matchesPlayed: 0,
                                       goalsScored: 0,
                                       redCards: 0,
                                       yellowCards: 0,
                                       yellowRedCrd: 0 )

let default_team_stats = TeamStats(wins: 0,
                                   draws: 0,
                                   losses: 0,
                                   totalScored: 0,
                                   totalAgainst: 0,
                                   goalDifference: 0,
                                   totalPoints: 0)

// Since missing structs cannot be invented, the following are not implemented
/*
struct LeagueTableItem: Codable {
    // Implementation omitted
}

struct TeamStats: Codable {
    // Implementation omitted
}

struct NewSession: Content {
    // Implementation omitted
}

// Other missing types like User, EmailController, etc., are not included as per your instructions.
*/
