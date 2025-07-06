import Vapor
import Fluent

final class LeagueController: RouteCollection {
    let repository: StandardControllerRepository<League>
    
    init(path: String) {
        self.repository = StandardControllerRepository<League>(path: path)
    }
    
    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)
        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.get(":id", "tabelle", use: getLeagueTable)
        route.delete(":id", use: repository.deleteID)
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        route.post(":id", "createSeason", ":number", ":switch", use: createSeason)
        route.get(":id", "seasons", use: getLeagueWithSeasons)
        route.get("code", ":code", use: getLeaguebyCode)
        route.get(":id", "teamCount", use: getNumberOfTeams)
        route.get("state", ":state", use: getLeaguesForState)
        
        route.get(":id", "goalLeaderBoard", use: getGoalLeaderBoard)
        route.get(":id", "redCardLeaderBoard", use: getRedCardLeaderBoard)
        route.get(":id", "yellowCardLeaderBoard", use: getYellowCardLeaderBoard)

        route.post(":id", "addSlide", use: addSlide)
        route.post(":id", "deleteSlide", ":slideID", use: deleteSlide)

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

    // Similar to HomepageController, we keep stats logic concise
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

    func createSeason(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let leagueID = req.parameters.get("id", as: UUID.self),
              let numberOfRounds = req.parameters.get("number", as: Int.self),
              let switchBool = req.parameters.get("switch", as: Bool.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing parameters"))
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                league.createSeason(db: req.db, numberOfRounds: numberOfRounds, switchBool: switchBool).map {
                    return .ok
                }
            }
    }

    func getLeaguebyCode(req: Request) -> EventLoopFuture<League> {
        guard let leagueCode = req.parameters.get("code", as: String.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league code"))
        }

        return League.query(on: req.db)
            .filter(\.$code == leagueCode)
            .with(\.$teams)
            .with(\.$seasons)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
    }

    func getLeagueWithSeasons(req: Request) -> EventLoopFuture<LeagueWithSeasons> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.query(on: req.db)
            .filter(\.$id == leagueID)
            .with(\.$seasons)
            .with(\.$teams)
            .first()
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .map { league in
                LeagueWithSeasons(league: league, seasons: league.seasons)
            }
    }

    func getNumberOfTeams(req: Request) -> EventLoopFuture<Int> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing league ID"))
        }

        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                league.$teams.query(on: req.db).count()
            }
    }

    func getLeaguesForState(req: Request) -> EventLoopFuture<[League]> {
        guard let state = req.parameters.get("state", as: Bundesland.self) else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid or missing state parameter"))
        }

        return League.query(on: req.db)
            .filter(\.$state == state)
            .all()
    }

    // MARK: - Leaderboards

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
                // 1) Build the dictionary: PlayerID -> (teamLogo, teamName, teamIdString)
                var playerTeamDict: [UUID: (String?, String?, String?)] = [:]
                for team in teams {
                    let teamIdString = team.id?.uuidString
                    for player in team.players {
                        if let pid = player.id {
                            // Store whichever info you want from the team
                            playerTeamDict[pid] = (team.logo, team.teamName, teamIdString)
                        }
                    }
                }
                
                // 2) Collect all the player IDs so we only fetch relevant events
                let playerIDs = playerTeamDict.keys.map { $0 }

                // 3) Fetch all events (of eventType) for those players
                return MatchEvent.query(on: req.db)
                    .filter(\.$player.$id ~~ playerIDs)
                    .filter(\.$type == eventType)
                    .all()
                    // 4) Map them to your LeaderBoard objects, passing the dictionary
                    .map { events in
                        self.mapEventsToLeaderBoard(events, playerTeamDict: playerTeamDict)
                    }
            }
    }

    private func mapEventsToLeaderBoard(_ events: [MatchEvent], playerTeamDict: [UUID: (String?, String?, String?)]) -> [LeaderBoard] {
        var playerEventCounts: [UUID: (name: String?, image: String?, number: String?, count: Int)] = [:]

        for event in events {
            let playerId = event.$player.id
            let playerInfo = (event.name, event.image, event.number)
            
            if let existing = playerEventCounts[playerId] {
                playerEventCounts[playerId] = (
                    existing.name,
                    existing.image,
                    existing.number,
                    existing.count + 1
                )
            } else {
                playerEventCounts[playerId] = (playerInfo.0, playerInfo.1, playerInfo.2, 1)
            }
        }

        return playerEventCounts.map { (playerId, data) in
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

    // MARK: - New Functions for SliderData Management
    
    /// Adds a new slide to the league's homepage slider data.
    func addSlide(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let leagueID = req.parameters.get("id", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(
                Abort(.badRequest, reason: "Invalid or missing league ID")
            )
        }
        
        let newSlideInput: NewSlideData
        do {
            newSlideInput = try req.content.decode(NewSlideData.self)
        } catch {
            return req.eventLoop.makeFailedFuture(
                Abort(.badRequest, reason: "Invalid slide data provided")
            )
        }
        
        // Create a new slide with an auto-generated id.
        let slide = SliderData(
            id: UUID(),
            image: newSlideInput.image,
            title: newSlideInput.title,
            description: newSlideInput.description,
            newsID: newSlideInput.newsID
        )
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                // Ensure all existing slides have an id.
                league.ensureSliderIDs()
                
                // Make sure there's a homepage to work with.
                var homepage = league.homepagedata ?? HomepageData(wochenbericht: "", youtubeLink: nil, sliderdata: [])
                homepage.sliderdata.append(slide)
                league.homepagedata = homepage
                return league.save(on: req.db).transform(to: .ok)
            }
    }
    
    /// Deletes an existing slide from the league's homepage slider data.
    func deleteSlide(req: Request) -> EventLoopFuture<HTTPStatus> {
        guard let leagueID = req.parameters.get("id", as: UUID.self),
              let slideID = req.parameters.get("slideID", as: UUID.self) else {
            return req.eventLoop.makeFailedFuture(
                Abort(.badRequest, reason: "Invalid or missing parameters")
            )
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "League not found"))
            .flatMap { league in
                // Ensure all existing slides have an id.
                league.ensureSliderIDs()
                
                guard var homepage = league.homepagedata else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.badRequest, reason: "Homepage data not found")
                    )
                }
                
                // Remove the slide matching the slideID.
                if let index = homepage.sliderdata.firstIndex(where: { $0.id == slideID }) {
                    homepage.sliderdata.remove(at: index)
                    league.homepagedata = homepage
                    return league.save(on: req.db).transform(to: .ok)
                } else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.notFound, reason: "Slide not found")
                    )
                }
            }
    }

}

// MARK: - Supporting Models

struct LeagueWithSeasons: Content {
    var league: League
    var seasons: [Season]
}

struct Table: Codable, Content {
    let items: [TableItem]
    let league: PublicLeagueOverview
}

struct TableItem: Codable, Content {
    var image: String
    var name: String
    var points: Int
    var id: UUID
    var goals: Int
    var ranking: Int
    var wins: Int
    var draws: Int
    var losses: Int
    var scored: Int
    var against: Int
    var difference: Int
}

struct LeaderBoard: Codable, Content {
    let name: String?
    let image: String?
    let number: String?
    let count: Double?
    let playerid: UUID?
    let teamimg: String?
    let teamName: String?
    let teamId: String?
}

struct TeamStats: Content, Codable {
    var wins: Int
    var draws: Int
    var losses: Int
    var totalScored: Int
    var totalAgainst: Int
    var goalDifference: Int
    var totalPoints: Int
    var totalYellowCards: Int
    var totalRedCards: Int
}

extension Int {
    func asDouble() -> Double {
        Double(self)
    }
}
