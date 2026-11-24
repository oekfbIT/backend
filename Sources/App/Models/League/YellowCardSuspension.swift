import Fluent
import Vapor

enum YellowCardSuspension {
    static func record(matchID: UUID, card: CardRequest, req: Request, notify: Bool = false) async throws -> HTTPStatus {
        let (match, assignment) = try await req.db.transaction { db in
            guard let match = try await Match.find(matchID, on: db) else { throw Abort(.notFound) }
            let assignment = try resolveCardAssignment(playerID: card.playerId, suppliedTeamID: card.teamId, match: match)
            if assignment == .home {
                updatePlayerCardStatus(in: &match.homeBlanket, playerId: card.playerId, cardType: .yellowCard)
            } else {
                updatePlayerCardStatus(in: &match.awayBlanket, playerId: card.playerId, cardType: .yellowCard)
            }
            try await match.update(on: db)
            let event = MatchEvent(
                matchId: matchID, type: .yellowCard, playerId: card.playerId,
                minute: card.minute, name: card.name, image: card.image, number: card.number,
                assign: assignment
            )
            try await event.create(on: db)
            try await apply(match: match, playerID: card.playerId, on: db)
            return (match, assignment)
        }

        do {
            try await StatsCacheManager.invalidateStats(for: match, on: req.db).get()
        } catch {
            req.logger.warning("Failed to invalidate statistics after recording a yellow card: \(error)")
        }
        if notify {
            _ = MatchPushNotifier.fire(.yellowCard, match: match, req: req, extra: [
                "minute": String(card.minute), "playerName": card.name ?? "",
                "playerNumber": card.number ?? "", "playerId": card.playerId.uuidString,
                "teamSide": assignment.rawValue
            ])
        }
        return .ok
    }

    private static func apply(match: Match, playerID: UUID, on db: Database) async throws {
        guard let seasonID = match.$season.id,
              let season = try await Season.find(seasonID, on: db),
              season.yellowCardSuspensionEnabled != false else { return }

        let matches = try await Match.query(on: db).filter(\.$season.$id == seasonID).all()
        let matchIDs = matches.compactMap(\.id)
        let events = try await MatchEvent.query(on: db)
            .filter(\.$match.$id ~~ matchIDs)
            .filter(\.$player.$id == playerID)
            .filter(\.$type == .yellowCard)
            .all()
        let counts = Dictionary(grouping: events, by: { $0.$match.id }).mapValues(\.count)
        let matchID = try match.requireID()
        guard counts[matchID] == 1 else { return }

        let appearances = matches.filter { previous in
            guard let id = previous.id, id != matchID,
                  PlayerStatisticsService.countsAsAppearance(previous) else { return false }
            return PlayerStatisticsService.contains(playerID, in: previous) || counts[id] != nil
        }
        let earlierCards = appearances
            .filter { precedes($0, match) }
            .sorted(by: precedes)
            .reversed()
            .map { $0.id.flatMap { counts[$0] } != nil }
        guard triggersSuspension(previousAppearances: earlierCards),
              let player = try await Player.find(playerID, on: db) else { return }

        let week: TimeInterval = 7 * 24 * 60 * 60
        player.yellowCardSuspensionSeasonID = seasonID
        player.yellowCardSuspensionUntil = Date().addingTimeInterval(week)

        // Keep the existing eligibility and expiry fields in sync for clients.
        let until = Date.viennaNow.addingTimeInterval(week)
        let hasLongerBlock = player.eligibility == .Gesperrt && (player.blockdate.map { $0 >= until } ?? true)
        if !hasLongerBlock {
            player.blockdate = until
            player.eligibility = .Gesperrt
        }
        try await player.update(on: db)
    }

    static func requireEligible(_ player: Player, for match: Match, at date: Date) throws {
        if let seasonID = match.$season.id,
           player.eligibility == .Gesperrt,
           player.yellowCardSuspensionSeasonID == seasonID,
           let until = player.yellowCardSuspensionUntil, date < until {
            throw Abort(.forbidden, reason: "\(player.name) ist wegen einer Gelbsperre für dieses Spiel gesperrt.")
        }
    }

    static func validateLineup(for match: Match, on db: Database) async throws {
        let ids = (match.homeBlanket?.players ?? []).map(\.id) + (match.awayBlanket?.players ?? []).map(\.id)
        guard !ids.isEmpty, let seasonID = match.$season.id else { return }
        let now = Date()
        let suspended = try await Player.query(on: db)
            .filter(\.$id ~~ ids)
            .filter(\.$eligibility == .Gesperrt)
            .filter(\.$yellowCardSuspensionSeasonID == seasonID)
            .filter(\.$yellowCardSuspensionUntil > now)
            .first()
        if let suspended { try requireEligible(suspended, for: match, at: now) }
    }

    static func triggersSuspension(previousAppearances: [Bool]) -> Bool {
        (previousAppearances.prefix(while: { $0 }).count + 1).isMultiple(of: 4)
    }

    private static func precedes(_ first: Match, _ second: Match) -> Bool {
        let firstDate = first.firstHalfStartDate ?? first.details.date ?? .distantPast
        let secondDate = second.firstHalfStartDate ?? second.details.date ?? .distantPast
        if firstDate != secondDate { return firstDate < secondDate }
        return first.details.gameday < second.details.gameday
    }
}
