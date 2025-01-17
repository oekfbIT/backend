import Vapor
import Fluent

final class MatchEventController: RouteCollection {
    let repository: StandardControllerRepository<MatchEvent>

    init(path: String) {
        self.repository = StandardControllerRepository<MatchEvent>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))

        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: deleteEvent)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        route.get("player", ":playerId", use: getPlayerEventsSummary) // New route for player events

    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    struct MatchEventSummary: Content {
        let goalCount: Int
        let redCardCount: Int
        let yellowCardCount: Int
        let yellowRedCardCount: Int
        let totalAppearances: Int
        let totalMatches: Int
    }

    func getPlayerEventsSummary(req: Request) throws -> EventLoopFuture<MatchEventSummary> {
        // Extract the player's UUID from the request parameters
        let playerId = try req.parameters.require("playerId", as: UUID.self)

        // Query the database to find all events associated with the player
        return MatchEvent.query(on: req.db)
            .filter(\.$player.$id == playerId)
            .all()
            .flatMap { events in
                // Extract unique match IDs from the events
                let matchIds = events.map { $0.$match.id }.compactMap { $0 }
                
                // Query the database to find all matches for the player
                return Match.query(on: req.db)
                    .filter(\.$id ~~ matchIds)
                    .all()
                    .map { matches in
                        // Count events by type
                        let goalCount = events.filter { $0.type == .goal }.count
                        let redCardCount = events.filter { $0.type == .redCard }.count
                        let yellowCardCount = events.filter { $0.type == .yellowCard }.count
                        let yellowRedCardCount = events.filter { $0.type == .yellowRedCard }.count

                        // Total appearances and matches
                        let totalAppearances = events.count
                        let totalMatches = matches.count

                        return MatchEventSummary(
                            goalCount: goalCount,
                            redCardCount: redCardCount,
                            yellowCardCount: yellowCardCount,
                            yellowRedCardCount: yellowRedCardCount,
                            totalAppearances: totalAppearances,
                            totalMatches: totalMatches
                        )
                    }
            }
    }

    // Custom delete function to handle event deletion and score/card adjustment
    func deleteEvent(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let eventId = try req.parameters.require("id", as: UUID.self)

        return MatchEvent.find(eventId, on: req.db)
            .unwrap(or: Abort(.notFound, reason: "Event not found"))
            .flatMap { event in
                // Find the associated match
                return Match.find(event.$match.id, on: req.db)
                    .unwrap(or: Abort(.notFound, reason: "Match not found"))
                    .flatMap { match in
                        // Handle event types separately: goal or card
                        switch event.type {
                        case .goal:
                            // If the event is a goal, adjust the score
                            return self.updateScoreForGoalRemoval(event: event, match: match, req: req)
                                .flatMap {
                                    // Delete the event after updating the score
                                    return event.delete(on: req.db).transform(to: .ok)
                                }
                        case .yellowCard, .redCard, .yellowRedCard:
                            // If the event is a card, adjust the card status and delete the event
                            return self.revertCardEvent(event: event, match: match, req: req)
                                .flatMap {
                                    // Delete the event after reverting the card
                                    return event.delete(on: req.db).transform(to: .ok)
                                }
                        default:
                            // For other event types, just delete the event
                            return event.delete(on: req.db).transform(to: .ok)
                        }
                    }
            }
    }

    // Helper function to update the match score after removing a goal event
    private func updateScoreForGoalRemoval(event: MatchEvent, match: Match, req: Request) -> EventLoopFuture<Void> {
        guard let assign = event.assign else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Event assignment is missing or invalid."))
        }

        // Ensure the match score is initialized
        if match.score.home == nil {
            match.score.home = 0
        }
        if match.score.away == nil {
            match.score.away = 0
        }

        switch assign {
        case .home:
            match.score.home = max(0, (match.score.home ?? 0) - 1) // Safely unwrap and decrement
        case .away:
            match.score.away = max(0, (match.score.away ?? 0) - 1) // Safely unwrap and decrement
        }

        // Save the updated match with the modified score
        return match.save(on: req.db)
    }

    // Helper function to revert a card event and update the blanket based on player team ID
    private func revertCardEvent(event: MatchEvent, match: Match, req: Request) -> EventLoopFuture<Void> {
        // Find the player's team (home or away) by checking their team ID against the match's home/away team
        return event.$player.get(on: req.db).flatMap { player in
            var blanket: Blankett?

            // Check whether the player's team matches the home or away team
            if player.$team.id == match.$homeTeam.id {
                blanket = match.homeBlanket
            } else if player.$team.id == match.$awayTeam.id {
                blanket = match.awayBlanket
            } else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Player team does not match home or away team"))
            }

            guard var mutableBlanket = blanket else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Blanket for the team not found."))
            }

            // Update the player's card status by removing the relevant card count
            if let index = mutableBlanket.players.firstIndex(where: { $0.id == player.id }) {
                switch event.type {
                case .redCard:
                    mutableBlanket.players[index].redCard = max(0, (mutableBlanket.players[index].redCard ?? 0) - 1)
                case .yellowCard:
                    mutableBlanket.players[index].yellowCard = max(0, (mutableBlanket.players[index].yellowCard ?? 0) - 1)
                case .yellowRedCard:
                    mutableBlanket.players[index].redYellowCard = max(0, (mutableBlanket.players[index].redYellowCard ?? 0) - 1)
                default:
                    break
                }
            }

            // Save the updated blanket back to the match
            if player.$team.id == match.$homeTeam.id {
                match.homeBlanket = mutableBlanket
            } else {
                match.awayBlanket = mutableBlanket
            }

            // Save the updated match with the reverted card status
            return match.save(on: req.db)
        }
    }
}

extension MatchEvent: Mergeable {
    func merge(from other: MatchEvent) -> MatchEvent {
        var merged = self
        merged.id = other.id
        merged.type = other.type
        merged.$match.id = other.$match.id
        merged.$player.id = other.$player.id
        merged.minute = other.minute
        merged.name = other.name
        merged.image = other.image
        merged.number = other.number
        merged.assign = other.assign
        merged.ownGoal = other.ownGoal

        return merged
    }
}
