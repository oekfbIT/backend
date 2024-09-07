import Vapor
import Fluent

func updatePlayerCardStatus(in blanket: inout Blankett?, playerId: UUID, cardType: MatchEventType) {
    // Ensure blanket is not nil
    guard blanket != nil else { return }

    // Work with the blanket directly
    if let index = blanket!.players.firstIndex(where: { $0.id == playerId }) {
        // Access the player directly in the original blanket
        switch cardType {
        case .redCard:
            blanket!.players[index].redCard = (blanket!.players[index].redCard ?? 0) + 1
        case .yellowCard:
            blanket!.players[index].yellowCard = (blanket!.players[index].yellowCard ?? 0) + 1
        case .yellowRedCard:
            blanket!.players[index].redYellowCard = (blanket!.players[index].redYellowCard ?? 0) + 1
        default:
            break
        }
    }
}

final class MatchController: RouteCollection {
    let repository: StandardControllerRepository<Match>

    init(path: String) {
        self.repository = StandardControllerRepository<Match>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        // Basic CRUD operations
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)
        route.get(use: repository.index)
        route.get(":id", use: getMatchByID)
        route.delete(":id", use: repository.deleteID)
        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)

        // Event-specific routes
        route.post(":id", "goal", use: addGoal)
        route.post(":id", "redCard", use: addRedCard)
        route.post(":id", "yellowCard", use: addYellowCard)
        route.post(":id", "yellowRedCard", use: addYellowRedCard)
        
        // Routes for adding players to blankets
        route.post(":id", "homeBlankett", "addPlayer", use: addPlayersToHomeBlankett)
        route.post(":id", "awayBlankett", "addPlayer", use: addPlayersToAwayBlankett)
        
        route.patch(":id", "startGame", use: startGame)
        route.patch(":id", "endFirstHalf", use: endFirstHalf)
        route.patch(":id", "startSecondHalf", use: startSecondHalf)
        route.patch(":id", "endGame", use: endGame)
        route.patch(":id", "submit", use: completeGame)
        route.patch(":id", "noShowGame", use: noShowGame)
        route.patch(":id", "spielabbruch", use: spielabbruch)

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // Function to handle adding a goal and updating the score
    func addGoal(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        struct GoalRequest: Content {
            let playerId: UUID
            let scoreTeam: String  // Indicates whether the goal is for the home or away team
            let minute: Int
            let name: String?
            let image: String?
            let number: String?
        }
        
        let goalRequest = try req.content.decode(GoalRequest.self)

        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                // Update the score based on the scoreTeam parameter
                switch goalRequest.scoreTeam.lowercased() {
                case "home":
                    match.score.home += 1
                case "away":
                    match.score.away += 1
                default:
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid team specified"))
                }

                // Save the updated match with the new score
                return match.save(on: req.db).flatMap {
                    // Create a goal event
                    let event = MatchEvent(match: match.id ?? UUID(),
                                           type: .goal,
                                           playerId: goalRequest.playerId,
                                           minute: goalRequest.minute, 
                                           name: goalRequest.name,
                                           image: goalRequest.image,
                                           number: goalRequest.number
                    )
                    event.$match.id = match.id!
                    
                    return event.save(on: req.db).map { .created }
                }
            }
    }

    // Function to handle adding a red card event
    func addRedCard(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return addCardEvent(req: req, cardType: .redCard)
    }

    // Function to handle adding a yellow card event
    func addYellowCard(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return addCardEvent(req: req, cardType: .yellowCard)
    }

    // Function to handle adding a yellow-red card event
    func addYellowRedCard(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return addCardEvent(req: req, cardType: .yellowRedCard)
    }

    // Helper function to handle card events
    private func addCardEvent(req: Request, cardType: MatchEventType) -> EventLoopFuture<HTTPStatus> {
        // Use a do-catch block to safely handle any errors thrown during parameter retrieval
        do {
            let matchId = try req.parameters.require("id", as: UUID.self)

            // Define the CardRequest struct inside the do-catch block
            struct CardRequest: Content {
                let playerId: UUID
                let teamId: UUID
                let minute: Int
                let name: String?
                let image: String?
                let number: String?
            }

            // Decode the request content and handle any potential decoding errors
            let cardRequest = try req.content.decode(CardRequest.self)

            // Find the match based on the matchId
            return Match.find(matchId, on: req.db)
                .unwrap(or: Abort(.notFound))
                .flatMap { match in
                    // Check if the teamId matches either home or away team
                    if cardRequest.teamId == match.$homeTeam.id {
                        updatePlayerCardStatus(in: &match.homeBlanket, playerId: cardRequest.playerId, cardType: cardType)
                    } else if cardRequest.teamId == match.$awayTeam.id {
                        updatePlayerCardStatus(in: &match.awayBlanket, playerId: cardRequest.playerId, cardType: cardType)
                    } else {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Team ID does not match home or away team."))
                    }

                    // Save the updated match
                    return match.save(on: req.db).flatMap {
                        // Create a card event
                        let event = MatchEvent(match: match.id ?? UUID(),
                                               type: cardType,
                                               playerId: cardRequest.playerId,
                                               minute: cardRequest.minute,
                                               name: cardRequest.name,
                                               image: cardRequest.image,
                                               number: cardRequest.number)
                        if let matchId = match.id {
                            event.$match.id = matchId
                        } else {
                            return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Match ID is missing."))
                        }
                        return event.create(on: req.db).transform(to: .ok)
                    }
                }

        } catch {
            // Handle any errors that may occur during request parameter extraction or content decoding
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid request parameters: \(error.localizedDescription)"))
        }
    }

    // Function to retrieve a match by ID
    func getMatchByID(req: Request) throws -> EventLoopFuture<Match> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        return Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$events)
            .first()
            .unwrap(or: Abort(.notFound))
    }

    // Function to add players to the homeBlankett
        func addPlayersToHomeBlankett(req: Request) throws -> EventLoopFuture<HTTPStatus> {
            let matchId = try req.parameters.require("id", as: UUID.self)
            let addPlayersRequest = try req.content.decode(AddPlayersRequest.self)

            return Match.find(matchId, on: req.db)
                .unwrap(or: Abort(.notFound))
                .flatMap { match in
                    // Initialize homeBlankett if nil
                    if match.homeBlanket == nil {
                        match.homeBlanket = Blankett(name: match.$homeTeam.name, dress: match.homeTeam.trikot.home, logo: nil, players: [])
                    }

                    // Iterate over the playerIds and add them to the blanket
                    let futures = addPlayersRequest.playerIds.map { playerId in
                        Player.find(playerId, on: req.db)
                            .unwrap(or: Abort(.notFound))
                            .map { player in
                                match.homeBlanket?.players.append(PlayerOverview(
                                    id: player.id!,
                                    sid: player.sid,
                                    name: player.name,
                                    number: Int(player.number) ?? 0,
                                    image: player.image,
                                    yellowCard: 0,
                                    redYellowCard: 0,
                                    redCard: 0
                                ))
                            }
                    }

                    return futures.flatten(on: req.eventLoop).flatMap {_ in 
                        return match.save(on: req.db).transform(to: .ok)
                    }
                }
        }

        // Function to add players to the awayBlankett
        func addPlayersToAwayBlankett(req: Request) throws -> EventLoopFuture<HTTPStatus> {
            let matchId = try req.parameters.require("id", as: UUID.self)
            let addPlayersRequest = try req.content.decode(AddPlayersRequest.self)

            return Match.find(matchId, on: req.db)
                .unwrap(or: Abort(.notFound))
                .flatMap { match in
                    // Initialize awayBlankett if nil
                    if match.awayBlanket == nil {
                        match.awayBlanket = Blankett(name: match.$awayTeam.name, dress: match.awayTeam.trikot.away, logo: nil, players: [])
                    }

                    // Iterate over the playerIds and add them to the blanket
                    let futures = addPlayersRequest.playerIds.map { playerId in
                        Player.find(playerId, on: req.db)
                            .unwrap(or: Abort(.notFound))
                            .map { player in
                                match.awayBlanket?.players.append(PlayerOverview(
                                    id: player.id!,
                                    sid: player.sid,
                                    name: player.name,
                                    number: Int(player.number) ?? 0,
                                    image: player.image,
                                    yellowCard: 0,
                                    redYellowCard: 0,
                                    redCard: 0
                                ))
                            }
                    }

                    return futures.flatten(on: req.eventLoop).flatMap {_ in 
                        return match.save(on: req.db).transform(to: .ok)
                    }
                }
        }
    
    func startGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .first
                match.firstHalfStartDate = Date()
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func endFirstHalf(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .halftime
                match.firstHalfEndDate = Date()
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func startSecondHalf(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .second
                match.secondHalfStartDate = Date()
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func endGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .completed
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func completeGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        struct Spielbericht: Content {
            let text: String?
        }

        let berichtRequest = try req.content.decode(Spielbericht.self)

        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                // 1. Set the status of the match to .submitted
                match.status = .submitted
                match.bericht = berichtRequest.text

                guard let matchID = match.id, let refID = match.$referee.id else {
                    return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Referee not found"))
                }

                // 2. Only create Strafsenat if the text is not nil or empty
                if let text = berichtRequest.text, !text.isEmpty {
                    let strafsenat = Strafsenat(matchID: matchID, refID: refID, text: text, offen: true)
                    return strafsenat.create(on: req.db).flatMap {
                        // Proceed to get the league of the match and handle the rest
                        return match.$homeTeam.get(on: req.db)
                            .flatMap { homeTeam in
                                return homeTeam.$league.get(on: req.db)
                            }.flatMap { league in
                                guard let hourlyRate = league?.hourly else {
                                    return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Hourly rate not found for league"))
                                }

                                // 3. Get the referee of the match and reduce their balance by the hourly rate
                                return match.$referee.get(on: req.db)
                                    .unwrap(or: Abort(.notFound, reason: "Referee not found"))
                                    .flatMap { referee in
                                        referee.balance = (referee.balance ?? 0) - hourlyRate
                                        
                                        // Save both the match and the updated referee
                                        let saveMatch = match.save(on: req.db)
                                        let saveReferee = referee.save(on: req.db)
                                        
                                        return saveMatch.and(saveReferee).transform(to: .ok)
                                    }
                            }
                    }
                } else {
                    // If no text, just proceed without creating Strafsenat
                    return match.$homeTeam.get(on: req.db)
                        .flatMap { homeTeam in
                            return homeTeam.$league.get(on: req.db)
                        }.flatMap { league in
                            guard let hourlyRate = league?.hourly else {
                                return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Hourly rate not found for league"))
                            }

                            // 3. Get the referee of the match and reduce their balance by the hourly rate
                            return match.$referee.get(on: req.db)
                                .unwrap(or: Abort(.notFound, reason: "Referee not found"))
                                .flatMap { referee in
                                    referee.balance = (referee.balance ?? 0) - hourlyRate
                                    
                                    // Save both the match and the updated referee
                                    let saveMatch = match.save(on: req.db)
                                    let saveReferee = referee.save(on: req.db)
                                    
                                    return saveMatch.and(saveReferee).transform(to: .ok)
                                }
                        }
                }
            }
    }


    func noShowGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        struct NoShowRequest: Content {
            let winningTeam: String // "home" or "away"
        }
        let noShowRequest = try req.content.decode(NoShowRequest.self)

        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                switch noShowRequest.winningTeam.lowercased() {
                case "home":
                    match.score = Score(home: 6, away: 0)
                case "away":
                    match.score = Score(home: 0, away: 6)
                default:
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid winning team specified"))
                }

                match.status = .completed
                return match.save(on: req.db).transform(to: .ok)
            }
    }
    
    func spielabbruch(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .abbgebrochen
                return match.save(on: req.db).transform(to: .ok)
            }
    }

}

struct AddPlayersRequest: Content {
    let playerIds: [UUID]
}
