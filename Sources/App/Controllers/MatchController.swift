import Vapor
import Fluent

struct LeagueMatches: Codable, Content{
    var matches: [Match]
    var league: String
}

struct LeagueMatchesShort: Codable, Content{
    var matches: [PublicMatchShort]
    var league: String
}
// Define the CardRequest struct inside the do-catch block
struct CardRequest: Content {
    let playerId: UUID
    let teamId: UUID
    let minute: Int
    let name: String?
    let image: String?
    let number: String?
}

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
    let emailController: EmailController

    init(path: String) {
        self.repository = StandardControllerRepository<Match>(path: path)
        self.emailController = EmailController()
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))

        route.post(use: repository.create)
        route.post("create", "internal", use: createInternal)
        
        route.post("batch", use: repository.createBatch)
        route.get("livescore",use: getLiveScore)

        route.get(use: repository.index)

        route.get(":id", use: getMatchByID)
        route.get("league", ":matchID", use: getLeagueFromMatch)

        route.get(":id", "resetGame" , use: resetGame)
        route.get(":id", "resetHalftime" , use: resetHalftime)
        
        route.delete(":id", use: repository.deleteID)
        
        route.patch(":id", use: updateID)
        route.patch("batch", use: repository.updateBatch)

        // Event-specific routes
        route.post(":id", "toggle", use: toggleDress)
        route.post(":id", "goal", use: addGoal)
        route.post(":id", "redCard", use: addRedCard)
        route.post(":id", "yellowCard", use: addYellowCard)
        route.post(":id", "yellowRedCard", use: addYellowRedCard)

        // Routes for adding players to blankets
        route.post(":id", "homeBlankett", "addPlayer", use: addPlayerToHomeBlankett)
        route.post(":id", "awayBlankett", "addPlayer", use: addPlayerToAwayBlankett)
        
        route.delete(":id", ":playerId", "homeBlankett", "removePlayer", use: removePlayerFromHomeBlankett)
        route.delete(":id", ":playerId", "awayBlankett", "removePlayer", use: removePlayerFromAwayBlankett)

        route.patch(":id", "startGame", use: startGame)
        route.patch(":id", "endFirstHalf", use: endFirstHalf)
        route.patch(":id", "startSecondHalf", use: startSecondHalf)
        route.patch(":id", "endGame", use: endGame)
        route.patch(":id", "submit", use: completeGame)
        route.patch(":id", "noShowGame", use: noShowGame)
        route.patch(":id", "teamcancel", use: teamCancelGame)
        route.patch(":id", "spielabbruch", use: spielabbruch)
        route.patch(":id", "done", use: done)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func updateID(req: Request) throws -> EventLoopFuture<Match> {
        do {
            guard let id = req.parameters.get("id", as: UUID.self) else {
                throw Abort(.badRequest, reason: "Invalid or missing ID parameter.")
            }

            let updatedItem: Match
            do {
                updatedItem = try req.content.decode(Match.self)
            } catch {
                print("Decoding error: \(error)")
                throw Abort(.badRequest, reason: "Invalid JSON payload.")
            }

            return Match.find(id, on: req.db)
                .unwrap(or: Abort(.notFound, reason: "Match not found."))
                .flatMap { existingMatch in
                    let mergedMatch = existingMatch.merge(from: updatedItem)
                    return mergedMatch.update(on: req.db).map { mergedMatch }
                }
                .flatMapErrorThrowing { error in
                    print("Error updating match: \(error)")
                    throw error
                }
        } catch {
            print("Error in updateID: \(error)")
            throw error
        }
    }

    func toggleDress(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        struct ToggleRequest: Content {
            let team: String // "home" or "away"
        }
        
        let toggleRequest = try req.content.decode(ToggleRequest.self)
        
        return Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$homeTeam) // Eager load home team
            .with(\.$awayTeam) // Eager load away team
            .first()
            .unwrap(or: Abort(.notFound, reason: "Match not found"))
            .flatMap { match in
                switch toggleRequest.team.lowercased() {
                case "home":
                    guard let homeBlanket = match.homeBlanket else {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Home blanket not found"))
                    }
                    
                    // Toggle the dress for the home team
                    if homeBlanket.dress == match.homeTeam.trikot.home {
                        match.homeBlanket?.dress = match.homeTeam.trikot.away
                    } else {
                        match.homeBlanket?.dress = match.homeTeam.trikot.home
                    }
                    
                case "away":
                    guard let awayBlanket = match.awayBlanket else {
                        return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Away blanket not found"))
                    }
                    
                    // Toggle the dress for the away team
                    if awayBlanket.dress == match.awayTeam.trikot.home {
                        match.awayBlanket?.dress = match.awayTeam.trikot.away
                    } else {
                        match.awayBlanket?.dress = match.awayTeam.trikot.home
                    }
                    
                default:
                    return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid team specified. Must be 'home' or 'away'."))
                }
                
                // Save the updated match and return HTTP status .ok
                return match.save(on: req.db).transform(to: .ok)
            }
    }
    
    func getLiveScore(req: Request) throws -> EventLoopFuture<[LeagueMatches]> {
        return Match.query(on: req.db)
            .filter(\.$status ~~ [.first, .second, .halftime])  // Filter matches that are in progress
            .with(\.$season) { seasonQuery in  // Eager load the season and related league
                seasonQuery.with(\.$league)  // Load the league through the season
            }
            .all()
            .flatMap { matches in
                // Group matches by the league name through season's league
                var leagueMatchesDict = [String: LeagueMatches]()

                for match in matches {
                    guard let league = match.$season.value??.$league.value else {
                        continue  // Skip matches without a valid league
                    }

                    let leagueName = league?.name  // Retrieve league name

                    if leagueMatchesDict[leagueName ?? "Nicht Gennant"] == nil {
                        leagueMatchesDict[leagueName ??  "Nicht Gennant"] = LeagueMatches(matches: [], league: leagueName ??  "Nicht Gennant")
                    }

                    leagueMatchesDict[leagueName ??  "Nicht Gennant"]?.matches.append(match)
                }

                // Convert the dictionary to an array of LeagueMatches
                let leagueMatchesArray = Array(leagueMatchesDict.values)
                return req.eventLoop.makeSucceededFuture(leagueMatchesArray)
            }
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
            let assign: MatchAssignment?
            let ownGoal: Bool?
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
                                           number: goalRequest.number,
                                           assign: goalRequest.assign,
                                           ownGoal: goalRequest.ownGoal
                    )
                    event.$match.id = match.id!
                    
                    return event.save(on: req.db).map { .created }
                }
            }
    }

    // Function to handle adding a red card event
    func addRedCard(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let calendar = Calendar.current
        let currentDate = Date.viennaNow

        // Calculate the block date (8 days from now at 12:00 PM)
        guard let futureDate = calendar.date(byAdding: .day, value: 8, to: currentDate) else {
            throw Abort(.internalServerError, reason: "Failed to calculate block date")
        }

        var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = 7
        components.minute = 0
        components.second = 0

        guard let blockDate = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Failed to set block date to 12 PM")
        }

        // Decode request first
        let cardRequest = try req.content.decode(CardRequest.self)

        // First, call addCardEvent
        return addCardEvent(req: req, cardType: .redCard)
            .flatMap { _ in
                // If addCardEvent succeeds, find the player and update their details
                Player.find(cardRequest.playerId, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Player not found"))
                    .flatMap { player in
                        player.blockdate = blockDate
                        player.eligibility = .Gesperrt
                        return player.save(on: req.db)
                    }
            }
            .transform(to: .ok)
    }

    func addYellowCard(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let calendar = Calendar.current
        let currentDate = Date.viennaNow

        guard let futureDate = calendar.date(byAdding: .day, value: 8, to: currentDate) else {
            throw Abort(.internalServerError, reason: "Failed to calculate block date")
        }

        var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = 7
        components.minute = 0
        components.second = 0

        guard let blockDate = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Failed to set block date to 12 PM")
        }

        let cardRequest = try req.content.decode(CardRequest.self)

        return addCardEvent(req: req, cardType: .yellowCard)
            .flatMap {_ in 
                MatchEvent.query(on: req.db)
                    .filter(\.$player.$id == cardRequest.playerId)
                    .filter(\.$type == .yellowCard)
                    .count()
                    .flatMap { yellowCardCount in
                        let isFourthCard = (yellowCardCount % 4) == 0
                        guard isFourthCard else {
                            return req.eventLoop.makeSucceededFuture(.ok)
                        }

                        return Player.find(cardRequest.playerId, on: req.db)
                            .unwrap(or: Abort(.notFound, reason: "Player not found"))
                            .flatMap { player in
                                player.blockdate = blockDate
                                player.eligibility = .Gesperrt
                                return player.save(on: req.db).transform(to: .ok)
                            }
                    }
            }
    }

    func addYellowRedCard(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let calendar = Calendar.current
        let currentDate = Date.viennaNow

        // Calculate the block date (8 days from now at 12:00 PM)
        guard let futureDate = calendar.date(byAdding: .day, value: 8, to: currentDate) else {
            throw Abort(.internalServerError, reason: "Failed to calculate block date")
        }

        var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = 7
        components.minute = 0
        components.second = 0

        guard let blockDate = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Failed to set block date to 12 PM")
        }

        // Decode request first
        let cardRequest = try req.content.decode(CardRequest.self)

        // First, call addCardEvent
        return addCardEvent(req: req, cardType: .yellowRedCard)
            .flatMap { _ in
                // If addCardEvent succeeds, find the player and update their details
                Player.find(cardRequest.playerId, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Player not found"))
                    .flatMap { player in
                        player.blockdate = blockDate
                        player.eligibility = .Gesperrt
                        return player.save(on: req.db)
                    }
            }
            .transform(to: .ok) // Ensure final response is HTTP 200 OK
    }

    // Helper function to handle card events
    private func addCardEvent(req: Request, cardType: MatchEventType) -> EventLoopFuture<HTTPStatus> {
        // Use a do-catch block to safely handle any errors thrown during parameter retrieval
        do {
            let matchId = try req.parameters.require("id", as: UUID.self)

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

    func addPlayerToHomeBlankett(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // Extract the match ID from the request parameters
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        // Define the expected structure of the incoming request body
        struct PlayerRequest: Content {
            let playerId: UUID
            let number: Int  // Overridden player number
            let coach: Trainer?
        }
        
        // Decode the request body into the PlayerRequest structure
        let playerRequest = try req.content.decode(PlayerRequest.self)

        // Fetch the match from the database
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Match with ID \(matchId) not found."))
            .flatMap { match in
                // Initialize homeBlanket if it's nil
                if match.homeBlanket == nil {
                    match.homeBlanket = Blankett(
                        name: match.$homeTeam.name,
                        dress: match.homeTeam.trikot.home,
                        logo: nil,
                        players: [],
                        coach: playerRequest.coach
                    )
                }
                
                // Check if the home team already has 12 or more players
                if (match.homeBlanket?.players.count ?? 0) >= 12 {
                    // Return a failed future with a conflict error
                    return req.eventLoop.makeFailedFuture(
                        Abort(.conflict, reason: "Home team already has 12 players.")
                    )
                }

                // Proceed to find the player to be added or updated
                return Player.find(playerRequest.playerId, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Player with ID \(playerRequest.playerId) not found."))
                    .flatMap { player in
                        // Check if the player is already in the homeBlanket
                        if let index = match.homeBlanket?.players.firstIndex(where: { $0.id == player.id }) {
                            // Update the player's number if they already exist
                            match.homeBlanket?.players[index].number = playerRequest.number
                        } else {
                            // Add the new player to the homeBlanket
                            match.homeBlanket?.players.append(PlayerOverview(
                                id: player.id!,
                                sid: player.sid,
                                name: player.name,
                                number: playerRequest.number,
                                image: player.image,
                                yellowCard: 0,
                                redYellowCard: 0,
                                redCard: 0
                            ))
                        }
                        // Save the updated match to the database
                        return match.save(on: req.db).transform(to: .ok)
                    }
            }
    }

    func addPlayerToAwayBlankett(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // Extract the match ID from the request parameters
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        // Define the expected structure of the incoming request body
        struct PlayerRequest: Content {
            let playerId: UUID
            let number: Int  // Overridden player number
            let coach: Trainer?
        }
        
        // Decode the request body into the PlayerRequest structure
        let playerRequest = try req.content.decode(PlayerRequest.self)

        // Fetch the match from the database
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Match with ID \(matchId) not found."))
            .flatMap { match in
                // Initialize awayBlanket if it's nil
                if match.awayBlanket == nil {
                    match.awayBlanket = Blankett(
                        name: match.$awayTeam.name,
                        dress: match.awayTeam.trikot.away,
                        logo: nil,
                        players: [],
                        coach: playerRequest.coach
                    )
                }
                
                // Check if the away team already has 12 or more players
                if (match.awayBlanket?.players.count ?? 0) >= 12 {
                    // Return a failed future with a conflict error
                    return req.eventLoop.makeFailedFuture(
                        Abort(.conflict, reason: "Away team already has 12 players.")
                    )
                }

                // Proceed to find the player to be added or updated
                return Player.find(playerRequest.playerId, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Player with ID \(playerRequest.playerId) not found."))
                    .flatMap { player in
                        // Safely unwrap player.id
                        guard let playerId = player.id else {
                            return req.eventLoop.makeFailedFuture(
                                Abort(.internalServerError, reason: "Player ID is missing.")
                            )
                        }
                        
                        // Check if the player is already in the awayBlanket
                        if let index = match.awayBlanket?.players.firstIndex(where: { $0.id == playerId }) {
                            // Update the player's number if they already exist
                            match.awayBlanket?.players[index].number = playerRequest.number
                        } else {
                            // Add the new player to the awayBlanket
                            match.awayBlanket?.players.append(PlayerOverview(
                                id: playerId,
                                sid: player.sid,
                                name: player.name,
                                number: playerRequest.number,
                                image: player.image,
                                yellowCard: 0,
                                redYellowCard: 0,
                                redCard: 0
                            ))
                        }
                        
                        // Save the updated match to the database
                        return match.save(on: req.db).transform(to: .ok)
                    }
            }
    }

    func removePlayerFromHomeBlankett(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        let playerId = try req.parameters.require("playerId", as: UUID.self)

        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                // Ensure the blanket exists
                guard let homeBlanket = match.homeBlanket else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Home blanket not found"))
                }

                // Find the player in the homeBlankett and remove them
                if let index = homeBlanket.players.firstIndex(where: { $0.id == playerId }) {
                    match.homeBlanket?.players.remove(at: index)
                } else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Player not found in home blanket"))
                }

                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func removePlayerFromAwayBlankett(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        let playerId = try req.parameters.require("playerId", as: UUID.self)  // Fix this line to extract from parameters

        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                // Ensure the blanket exists
                guard let awayBlanket = match.awayBlanket else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Away blanket not found"))
                }

                // Find the player in the awayBlankett and remove them
                if let index = awayBlanket.players.firstIndex(where: { $0.id == playerId }) {
                    match.awayBlanket?.players.remove(at: index)
                } else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Player not found in away blanket"))
                }

                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func startGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .first
                match.firstHalfStartDate = Date.viennaNow
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func endFirstHalf(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .halftime
                match.firstHalfEndDate = Date.viennaNow
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func startSecondHalf(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .second
                match.secondHalfStartDate = Date.viennaNow
                return match.save(on: req.db).transform(to: .ok)
            }
    }

    func endGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .completed
                match.secondHalfEndDate = Date.viennaNow
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
                if match.status != .abbgebrochen {
                    match.status = .submitted
                }

                match.bericht = berichtRequest.text

                guard let matchID = match.id, let refID = match.$referee.id else {
                    return req.eventLoop.makeFailedFuture(Abort(.notFound, reason: "Referee not found"))
                }

                // Check if Strafsenat already exists for this match
                return Strafsenat.query(on: req.db)
                    .filter(\.$match.$id == matchID)
                    .first()
                    .flatMap { existingStrafsenat in
                        // If a Strafsenat already exists, skip creation
                        if existingStrafsenat != nil {
                            return self.handleMatchCompletion(req: req, match: match, matchID: matchID)
                        }

                        // Proceed with Strafsenat creation if not found
                        if let text = berichtRequest.text, !text.isEmpty {
                            let strafsenat = Strafsenat(matchID: matchID, refID: refID, text: text, offen: true)
                            return strafsenat.create(on: req.db).flatMap {
                                return self.handleMatchCompletion(req: req, match: match, matchID: matchID)
                            }
                        } else {
                            // If no text, proceed without creating Strafsenat
                            return self.handleMatchCompletion(req: req, match: match, matchID: matchID)
                        }
                    }
            }
    }

    // Helper function to handle the remaining match completion logic
    private func handleMatchCompletion(req: Request, match: Match, matchID: UUID) -> EventLoopFuture<HTTPStatus> {
        return match.$homeTeam.get(on: req.db)
            .flatMap { homeTeam in
                return homeTeam.$league.get(on: req.db)
            }.flatMap { league in
                guard let hourlyRate = league?.hourly else {
                    return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Hourly rate not found for league"))
                }

                return match.$referee.get(on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Referee not found"))
                    .flatMap { referee in
                        if !(match.paid ?? false) {
                            referee.balance = (referee.balance ?? 0) - hourlyRate
                            match.paid = true
                        }

                        let saveMatch = match.save(on: req.db)
                        let saveReferee = referee.save(on: req.db)

                        return saveMatch.and(saveReferee).transform(to: .ok)
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
                let winningTeamId: UUID
                
                switch noShowRequest.winningTeam.lowercased() {
                case "home":
                    match.score = Score(home: 6, away: 0)
                    winningTeamId = match.$homeTeam.id
                case "away":
                    match.score = Score(home: 0, away: 6)
                    winningTeamId = match.$awayTeam.id
                default:
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid winning team specified"))
                }
                
                match.status = .cancelled
                
                return match.save(on: req.db)
                    .flatMap {
                        return Team.find(winningTeamId, on: req.db)
                            .unwrap(or: Abort(.notFound))
                            .flatMap { team in
                                team.points += 3
                                
                                return team.save(on: req.db).map {
                                    HTTPStatus.ok
                                }
                            }
                    }
            }
        }
    }
    
func teamCancelGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
    let matchId = try req.parameters.require("id", as: UUID.self)

    struct NoShowRequest: Content {
        let winningTeam: String // "home" or "away"
    }

    let noShowRequest = try req.content.decode(NoShowRequest.self)

    return Match.query(on: req.db)
        .with(\.$homeTeam)
        .with(\.$awayTeam)
        .with(\.$referee) { $0.with(\.$user) }
        .filter(\.$id == matchId)
        .first()
        .unwrap(or: Abort(.notFound))
        .flatMap { match in
            let winningTeamId: UUID
            let losingTeamId: UUID
            var opponentEmail: String? = nil

            switch noShowRequest.winningTeam.lowercased() {
            case "home":
                match.score = Score(home: 6, away: 0)
                winningTeamId = match.$homeTeam.id
                losingTeamId = match.$awayTeam.id
                opponentEmail = match.homeTeam.usremail

            case "away":
                match.score = Score(home: 0, away: 6)
                winningTeamId = match.$awayTeam.id
                losingTeamId = match.$homeTeam.id
                opponentEmail = match.awayTeam.usremail

            default:
                return req.eventLoop.future(error: Abort(.badRequest, reason: "Invalid winning team specified"))
            }

            match.status = .cancelled

            return match.save(on: req.db).flatMap {
                Team.find(winningTeamId, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Winning team not found"))
                    .and(Team.find(losingTeamId, on: req.db)
                        .unwrap(or: Abort(.notFound, reason: "Losing team not found")))
                    .flatMap { winningTeam, losingTeam in
                        winningTeam.points += 3

                        let cancelled = losingTeam.cancelled ?? 0
                        guard cancelled < 3 else {
                            return req.eventLoop.makeFailedFuture(
                                Abort(.badRequest, reason: "Schon 3 Absagen gemacht diese Saison.")
                            )
                        }

                        let newCancelled = cancelled + 1
                        losingTeam.cancelled = newCancelled

                        let rechnungAmount: Int
                        switch newCancelled {
                        case 1: rechnungAmount = 170
                        case 2: rechnungAmount = 270
                        case 3: rechnungAmount = 370
                        default: rechnungAmount = 0
                        }

                        let invoiceNumber = UUID().uuidString
                        let balance = losingTeam.balance ?? 0

                        let rechnung = Rechnung(
                            team: losingTeam.id,
                            teamName: losingTeam.teamName,
                            number: invoiceNumber,
                            summ: Double(rechnungAmount),
                            topay: nil,
                            kennzeichen: "Spiel Absage: \(newCancelled)"
                        )

                        return rechnung.save(on: req.db).flatMap {
                            losingTeam.balance = balance - Double(rechnungAmount)

                            do {
                                try emailController.sendCancellationNotification(
                                    req: req,
                                    recipient: opponentEmail!,
                                    match: match
                                )

                                if let ref = match.referee,
                                   let refUser = ref.user {
                                    let refEmail = refUser.email
                                    try emailController.informRefereeCancellation(
                                        req: req,
                                        email: refEmail,
                                        name: ref.name ?? "Referee",
                                        match: match
                                    )
                                }
                            } catch {
                                print("Unable to send email. \(error)")
                            }

                            return losingTeam.save(on: req.db).flatMap {
                                winningTeam.save(on: req.db).transform(to: .ok)
                            }
                        }
                    }
            }
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
    
    func done(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)

        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                // Check the final score
                let homeScore = match.score.home
                let awayScore = match.score.away

                // Find both home and away teams
                let homeTeamFuture = match.$homeTeam.get(on: req.db)
                let awayTeamFuture = match.$awayTeam.get(on: req.db)

                return homeTeamFuture.and(awayTeamFuture).flatMap { homeTeam, awayTeam in
                    // Update points based on the final score
                    if homeScore > awayScore {
                        homeTeam.points += 3 // Home team wins
                    } else if awayScore > homeScore {
                        awayTeam.points += 3 // Away team wins
                    } else {
                        // It's a draw
                        homeTeam.points += 1
                        awayTeam.points += 1
                    }

                    // Save the updated team points
                    let saveHomeTeam = homeTeam.save(on: req.db)
                    let saveAwayTeam = awayTeam.save(on: req.db)

                    return saveHomeTeam.and(saveAwayTeam).flatMap {_ in 
                        // Update match status to 'done'
                        match.status = .done
                        return match.save(on: req.db).transform(to: .ok)
                    }
                }
            }
    }

    func resetGame(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                // Reset game status and score
                match.status = .pending
                match.firstHalfStartDate = nil
                match.secondHalfStartDate = nil
                match.firstHalfEndDate = nil
                match.secondHalfEndDate = nil
                match.score = Score(home: 0, away: 0)
                
                // Reset all player cards and goals in home blanket
                if var homeBlanket = match.homeBlanket {
                    for i in 0..<homeBlanket.players.count {
                        homeBlanket.players[i].yellowCard = 0
                        homeBlanket.players[i].redYellowCard = 0
                        homeBlanket.players[i].redCard = 0
                    }
                    match.homeBlanket = homeBlanket
                }
                
                // Reset all player cards and goals in away blanket
                if var awayBlanket = match.awayBlanket {
                    for i in 0..<awayBlanket.players.count {
                        awayBlanket.players[i].yellowCard = 0
                        awayBlanket.players[i].redYellowCard = 0
                        awayBlanket.players[i].redCard = 0
                    }
                    match.awayBlanket = awayBlanket
                }
                
                // Delete all MatchEvents associated with the match
                return MatchEvent.query(on: req.db)
                    .filter(\.$match.$id == matchId)
                    .delete()
                    .flatMap {
                        // Save the updated match
                        return match.save(on: req.db).transform(to: .ok)
                    }
            }
    }

    func resetHalftime(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let matchId = try req.parameters.require("id", as: UUID.self)
        
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { match in
                match.status = .halftime
                match.secondHalfStartDate = nil
                match.secondHalfEndDate = nil
                
                return match.save(on: req.db).transform(to: .ok)
            }
    }
    
    func getLeagueFromMatch(req: Request) throws -> EventLoopFuture<League> {
        // Extract the match ID from the request parameters
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        
        // Fetch the match from the database
        return Match.find(matchId, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Match with ID \(matchId) not found."))
            .flatMap { match in
                // Ensure the season exists for the match
                guard let seasonID = match.$season.id else {
                    return req.eventLoop.makeFailedFuture(
                        Abort(.notFound, reason: "Season not found for the match with ID \(matchId).")
                    )
                }
                
                // Fetch the season from the database
                return Season.find(seasonID, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Season with ID \(seasonID) not found."))
                    .flatMap { season in
                        // Ensure the league exists for the season
                        guard let leagueID = season.$league.id else {
                            return req.eventLoop.makeFailedFuture(
                                Abort(.notFound, reason: "League not found for the season with ID \(seasonID).")
                            )
                        }
                        
                        // Fetch the league from the database
                        return League.find(leagueID, on: req.db)
                            .unwrap(or: Abort(.notFound, reason: "League with ID \(leagueID) not found."))
                    }
            }
    }



extension MatchController {
    
    func createInternal(req: Request) throws -> EventLoopFuture<Match> {
        struct CreateInternalMatchRequest: Content {
            let homeTeamId: UUID
            let awayTeamId: UUID
            let gameday: Int
            let seasonId: UUID
        }
        
        // Decode request body
        let createRequest = try req.content.decode(CreateInternalMatchRequest.self)
        
        // Fetch the teams and the season
        let homeTeamFuture = Team.find(createRequest.homeTeamId, on: req.db).unwrap(or: Abort(.notFound, reason: "Home team not found."))
        let awayTeamFuture = Team.find(createRequest.awayTeamId, on: req.db).unwrap(or: Abort(.notFound, reason: "Away team not found."))
        let seasonFuture = Season.find(createRequest.seasonId, on: req.db).unwrap(or: Abort(.notFound, reason: "Season not found."))
        
        return homeTeamFuture.and(awayTeamFuture).and(seasonFuture).flatMap { (teams, season) in
            let (homeTeam, awayTeam) = teams
            
            // Create default MatchDetails
            let details = MatchDetails(
                gameday: createRequest.gameday,
                date: nil,
                stadium: nil,
                location: "Nicht Zugeordnet"
            )
            
            // Create Blankett for home and away teams
            let homeBlanket = Blankett(
                name: homeTeam.teamName,
                dress: homeTeam.trikot.home,
                logo: homeTeam.logo,
                players: [],
                coach: homeTeam.coach
            )
            
            let awayBlanket = Blankett(
                name: awayTeam.teamName,
                dress: awayTeam.trikot.away,
                logo: awayTeam.logo,
                players: [],
                coach: awayTeam.coach
            )
            
            // Create the Match instance
            let match = Match(
                details: details,
                homeTeamId: homeTeam.id!,
                awayTeamId: awayTeam.id!,
                homeBlanket: homeBlanket,
                awayBlanket: awayBlanket,
                score: Score(home: 0, away: 0),
                status: .pending
            )
            
            match.$season.id = season.id
            
            // Save the match to the database
            return match.create(on: req.db).map { match }
        }
    }
    
    
}

struct AddPlayersRequest: Content {
    let coach: Trainer?
    let playerIds: [UUID]
    
    init(coach: Trainer? = nil, playerIds: [UUID]) {
        self.coach = coach
        self.playerIds = playerIds
    }
}
