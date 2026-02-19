//
//  AppController+Match.swift
//  oekfbbackend
//
//  Created by Alon Yakobichvili
//

import Foundation
import Vapor
import Fluent

// MARK: - MATCH ENDPOINTS
extension AppController {
    // GET /app/match/:matchID
    func getMatchByID(req: Request) async throws -> AppModels.AppMatch {
        guard let matchID = req.parameters.get("matchID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid match ID.")
        }

        let query = Match.query(on: req.db)
            .filter(\.$id == matchID)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$season) { $0.with(\.$league) }
            .with(\.$events)

        guard let match = try await query.first() else {
            throw Abort(.notFound, reason: "Match not found.")
        }

        guard let season = match.season else {
            throw Abort(.notFound, reason: "Season not found for this match.")
        }

        guard let league = season.league else {
            throw Abort(.notFound, reason: "League not found for this match.")
        }

        let leagueOverview = try league.toAppLeagueOverview()
        let appSeason = try season.toAppSeason()

        let home = match.homeTeam
        let away = match.awayTeam

        let homeID = try home.requireID()
        let awayID = try away.requireID()

        let homeForm = try await Team.getRecentForm(for: homeID, on: req.db, onlyPrimarySeason: true)
        let awayForm = try await Team.getRecentForm(for: awayID, on: req.db, onlyPrimarySeason: true)

        let homeOverview = AppModels.AppTeamOverview(
            id: homeID,
            sid: home.sid ?? "",
            league: leagueOverview,
            points: home.points,
            logo: home.logo,
            name: home.teamName,
            shortName: home.shortName,
            stats: try? await StatsCacheManager.getTeamStats(for: homeID, on: req.db).get()
        )

        let awayOverview = AppModels.AppTeamOverview(
            id: awayID,
            sid: away.sid ?? "",
            league: leagueOverview,
            points: away.points,
            logo: away.logo,
            name: away.teamName,
            shortName: away.shortName,
            stats: try? await StatsCacheManager.getTeamStats(for: awayID, on: req.db).get()
        )

        let appEvents: [AppModels.AppMatchEvent] = try await match.events.asyncMap {
            try await $0.toAppMatchEvent(on: req)
        }

        return AppModels.AppMatch(
            id: try match.requireID(),
            details: match.details,
            score: match.score,
            season: appSeason,
            away: awayOverview,
            home: homeOverview,
            homeBlanket: match.homeBlanket ?? Blankett(
                name: home.teamName,
                dress: home.trikot.home,
                logo: home.logo,
                players: []
            ),
            awayBlanket: match.awayBlanket ?? Blankett(
                name: away.teamName,
                dress: away.trikot.away,
                logo: away.logo,
                players: []
            ),
            events: appEvents,
            status: match.status,
            firstHalfStartDate: match.firstHalfStartDate,
            secondHalfStartDate: match.secondHalfStartDate,
            firstHalfEndDate: match.firstHalfEndDate,
            secondHalfEndDate: match.secondHalfEndDate,
            homeForm: homeForm,
            awayForm: awayForm
        )
    }
}

// MARK: - Match Endpoints
extension AppController {

    func setupMatchRoutes(on route: RoutesBuilder) {
        // live score
        route.get("match", "livescore", use: getLiveScore)

        // matchday / season matchday / date (NOT inside :matchID group)
        route.get("match", "matchday", ":day", use: matchesForMatchday)
        route.get("match", "season", ":seasonID", "matchday", ":day", use: matchesForMatchdayForSeason)
        route.get("match", "date", ":date", use: matchesForDate)

        // NEW: available dates (primary seasons only)
        route.get("match", "availableDates", use: availableMatchDates)

        // ✅ single param name for everything under here: :matchID
        route.group("match", ":matchID") { match in
            match.get(use: getMatchByID)
            match.get("league", use: getLeagueFromMatch)

            match.get("resetGame", use: resetGame)
            match.get("resetHalftime", use: resetHalftime)

            match.post("toggle", use: toggleDress)
            match.post("goal", use: addGoal)
            match.post("redCard", use: addRedCard)
            match.post("yellowCard", use: addYellowCard)
            match.post("yellowRedCard", use: addYellowRedCard)

            match.post("homeBlankett", "addPlayer", use: addPlayerToHomeBlankett)
            match.post("awayBlankett", "addPlayer", use: addPlayerToAwayBlankett)

            match.delete(":playerId", "homeBlankett", "removePlayer", use: removePlayerFromHomeBlankett)
            match.delete(":playerId", "awayBlankett", "removePlayer", use: removePlayerFromAwayBlankett)

            match.patch("startGame", use: startGame)
            match.patch("endFirstHalf", use: endFirstHalf)
            match.patch("startSecondHalf", use: startSecondHalf)
            match.patch("endGame", use: endGame)
            match.patch("submit", use: completeGame)
            match.patch("noShowGame", use: noShowGame)
            match.patch("teamcancel", use: teamCancelGame)
            match.patch("spielabbruch", use: spielabbruch)
            match.patch("done", use: done)
        }

        // legacy keep (same param name)
        route.get("match", "league", ":matchID", use: getLeagueFromMatch)
    }

    // GET /app/match/livescore
    func getLiveScore(req: Request) async throws -> [LeagueMatches] {
        // Load ONLY what we need; no eager-load home/away teams to avoid missing-parent crashes.
        let matches = try await Match.query(on: req.db)
            .filter(\.$status ~~ [.first, .second, .halftime])
            .all()

        // Reuse your safe lookup + mapping (skips dangling refs).
        let lookup = try await buildMatchLookup(matches: matches, on: req.db)

        var mapped: [AppModels.AppMatchOverview] = []
        mapped.reserveCapacity(matches.count)

        for m in matches {
            if let ov = try await toAppMatchOverviewSafe(match: m, lookup: lookup, req: req) {
                mapped.append(ov)
            }
        }

        // Group by league name (season.league is String in your AppModels)
        let grouped = Dictionary(grouping: mapped) { $0.season.league }

        let leagues: [LeagueMatches] = grouped
            .map { leagueName, items in
                let sorted = items.sorted { lhs, rhs in
                    let lDate = lhs.details.date ?? .distantFuture
                    let rDate = rhs.details.date ?? .distantFuture
                    if lDate != rDate { return lDate < rDate }
                    return lhs.home.name < rhs.home.name
                }
                return LeagueMatches(league: leagueName.isEmpty ? "Nicht Gennant" : leagueName, matches: sorted)
            }
            .sorted { $0.league.localizedCaseInsensitiveCompare($1.league) == .orderedAscending }

        return leagues
    }

    // POST /app/match/:matchID/toggle
    func toggleDress(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct ToggleRequest: Content { let team: String }
        let toggleRequest = try req.content.decode(ToggleRequest.self)

        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }

        switch toggleRequest.team.lowercased() {
        case "home":
            guard let homeBlanket = match.homeBlanket else {
                throw Abort(.badRequest, reason: "Home blanket not found")
            }
            match.homeBlanket?.dress =
                (homeBlanket.dress == match.homeTeam.trikot.home)
                ? match.homeTeam.trikot.away
                : match.homeTeam.trikot.home

        case "away":
            guard let awayBlanket = match.awayBlanket else {
                throw Abort(.badRequest, reason: "Away blanket not found")
            }
            match.awayBlanket?.dress =
                (awayBlanket.dress == match.awayTeam.trikot.home)
                ? match.awayTeam.trikot.away
                : match.awayTeam.trikot.home

        default:
            throw Abort(.badRequest, reason: "Invalid team specified. Must be 'home' or 'away'.")
        }

        try await match.save(on: req.db)
        return .ok
    }

    // POST /app/match/:matchID/goal
    func addGoal(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct GoalRequest: Content {
            let playerId: UUID
            let scoreTeam: String
            let minute: Int
            let name: String?
            let image: String?
            let number: String?
            let assign: MatchAssignment?
            let ownGoal: Bool?
        }

        let goalRequest = try req.content.decode(GoalRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }

        switch goalRequest.scoreTeam.lowercased() {
        case "home": match.score.home += 1
        case "away": match.score.away += 1
        default: throw Abort(.badRequest, reason: "Invalid team specified")
        }

        try await match.save(on: req.db)

        let event = MatchEvent(
            matchId: match.id ?? UUID(),
            type: .goal,
            playerId: goalRequest.playerId,
            minute: goalRequest.minute,
            name: goalRequest.name,
            image: goalRequest.image,
            number: goalRequest.number,
            assign: goalRequest.assign,
            ownGoal: goalRequest.ownGoal
        )

        guard let mid = match.id else {
            throw Abort(.internalServerError, reason: "Match ID is missing after save.")
        }
        event.$match.id = mid
        try await event.save(on: req.db)

        return .created
    }

    // POST /app/match/:matchID/redCard
    func addRedCard(req: Request) async throws -> HTTPStatus {
        let cardRequest = try req.content.decode(CardRequest.self)

        _ = try await addCardEvent(req: req, cardType: .redCard)

        let calendar = Calendar.current
        let currentDate = Date.viennaNow
        guard let futureDate = calendar.date(byAdding: .day, value: 8, to: currentDate) else {
            throw Abort(.internalServerError, reason: "Failed to calculate block date")
        }

        var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = 7; components.minute = 0; components.second = 0
        guard let blockDate = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Failed to set block date to 7 AM")
        }

        guard let player = try await Player.find(cardRequest.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found")
        }

        player.blockdate = blockDate
        player.eligibility = .Gesperrt
        try await player.save(on: req.db)

        return .ok
    }

    // POST /app/match/:matchID/yellowCard
    func addYellowCard(req: Request) async throws -> HTTPStatus {
        let cardRequest = try req.content.decode(CardRequest.self)

        _ = try await addCardEvent(req: req, cardType: .yellowCard)

        let calendar = Calendar.current
        let currentDate = Date.viennaNow
        guard let futureDate = calendar.date(byAdding: .day, value: 8, to: currentDate) else {
            throw Abort(.internalServerError, reason: "Failed to calculate block date")
        }

        var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = 7; components.minute = 0; components.second = 0
        guard let blockDate = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Failed to set block date to 7 AM")
        }

        let yellowCardCount = try await MatchEvent.query(on: req.db)
            .join(Match.self, on: \MatchEvent.$match.$id == \Match.$id)
            .join(Season.self, on: \Match.$season.$id == \Season.$id)
            .filter(Season.self, \.$primary == true)
            .filter(\.$player.$id == cardRequest.playerId)
            .filter(\.$type == .yellowCard)
            .count()

        let isFourthCard = (yellowCardCount % 4) == 0
        guard isFourthCard else { return .ok }

        guard let player = try await Player.find(cardRequest.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found")
        }

        player.blockdate = blockDate
        player.eligibility = .Gesperrt
        try await player.save(on: req.db)

        return .ok
    }

    // POST /app/match/:matchID/yellowRedCard
    func addYellowRedCard(req: Request) async throws -> HTTPStatus {
        let cardRequest = try req.content.decode(CardRequest.self)

        _ = try await addCardEvent(req: req, cardType: .yellowRedCard)

        let calendar = Calendar.current
        let currentDate = Date.viennaNow
        guard let futureDate = calendar.date(byAdding: .day, value: 8, to: currentDate) else {
            throw Abort(.internalServerError, reason: "Failed to calculate block date")
        }

        var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = 7; components.minute = 0; components.second = 0
        guard let blockDate = calendar.date(from: components) else {
            throw Abort(.internalServerError, reason: "Failed to set block date to 7 AM")
        }

        guard let player = try await Player.find(cardRequest.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found")
        }

        player.blockdate = blockDate
        player.eligibility = .Gesperrt
        try await player.save(on: req.db)

        if let lastYellow = try await MatchEvent.query(on: req.db)
            .filter(\.$player.$id == (player.id ?? UUID()))
            .filter(\.$type == .yellowCard)
            .sort(\._$id, .descending)
            .first()
        {
            try await lastYellow.delete(on: req.db)
        }

        return .ok
    }

    // MARK: - Blankett players (home/away)

    // POST /app/match/:matchID/homeBlankett/addPlayer
    func addPlayerToHomeBlankett(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct PlayerRequest: Content {
            let playerId: UUID
            let number: Int
            let coach: Trainer?
        }
        let playerRequest = try req.content.decode(PlayerRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match with ID \(matchId) not found.")
        }

        if match.homeBlanket == nil {
            let homeTeam = try await match.$homeTeam.get(on: req.db)
            match.homeBlanket = Blankett(
                name: homeTeam.teamName,
                dress: homeTeam.trikot.home,
                logo: nil,
                players: [],
                coach: playerRequest.coach
            )
        }

        if (match.homeBlanket?.players.count ?? 0) >= 12 {
            throw Abort(.conflict, reason: "Home team already has 12 players.")
        }

        guard let player = try await Player.find(playerRequest.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player with ID \(playerRequest.playerId) not found.")
        }

        if let index = match.homeBlanket?.players.firstIndex(where: { $0.id == player.id }) {
            match.homeBlanket?.players[index].number = playerRequest.number
        } else {
            guard let pid = player.id else {
                throw Abort(.internalServerError, reason: "Player ID is missing.")
            }
            match.homeBlanket?.players.append(
                PlayerOverview(
                    id: pid,
                    sid: player.sid,
                    name: player.name,
                    number: playerRequest.number,
                    image: player.image,
                    yellowCard: 0,
                    redYellowCard: 0,
                    redCard: 0
                )
            )
        }

        try await match.save(on: req.db)
        return .ok
    }

    // POST /app/match/:matchID/awayBlankett/addPlayer
    func addPlayerToAwayBlankett(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct PlayerRequest: Content {
            let playerId: UUID
            let number: Int
            let coach: Trainer?
        }
        let playerRequest = try req.content.decode(PlayerRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match with ID \(matchId) not found.")
        }

        if match.awayBlanket == nil {
            let awayTeam = try await match.$awayTeam.get(on: req.db)
            match.awayBlanket = Blankett(
                name: awayTeam.teamName,
                dress: awayTeam.trikot.away,
                logo: nil,
                players: [],
                coach: playerRequest.coach
            )
        }

        if (match.awayBlanket?.players.count ?? 0) >= 12 {
            throw Abort(.conflict, reason: "Away team already has 12 players.")
        }

        guard let player = try await Player.find(playerRequest.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player with ID \(playerRequest.playerId) not found.")
        }

        guard let playerId = player.id else {
            throw Abort(.internalServerError, reason: "Player ID is missing.")
        }

        if let index = match.awayBlanket?.players.firstIndex(where: { $0.id == playerId }) {
            match.awayBlanket?.players[index].number = playerRequest.number
        } else {
            match.awayBlanket?.players.append(
                PlayerOverview(
                    id: playerId,
                    sid: player.sid,
                    name: player.name,
                    number: playerRequest.number,
                    image: player.image,
                    yellowCard: 0,
                    redYellowCard: 0,
                    redCard: 0
                )
            )
        }

        try await match.save(on: req.db)
        return .ok
    }

    // DELETE /app/match/:matchID/:playerId/homeBlankett/removePlayer
    func removePlayerFromHomeBlankett(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        let playerId = try req.parameters.require("playerId", as: UUID.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }

        guard let homeBlanket = match.homeBlanket else {
            throw Abort(.badRequest, reason: "Home blanket not found")
        }

        guard let index = homeBlanket.players.firstIndex(where: { $0.id == playerId }) else {
            throw Abort(.badRequest, reason: "Player not found in home blanket")
        }

        match.homeBlanket?.players.remove(at: index)
        try await match.save(on: req.db)
        return .ok
    }

    // DELETE /app/match/:matchID/:playerId/awayBlankett/removePlayer
    func removePlayerFromAwayBlankett(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        let playerId = try req.parameters.require("playerId", as: UUID.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }

        guard let awayBlanket = match.awayBlanket else {
            throw Abort(.badRequest, reason: "Away blanket not found")
        }

        guard let index = awayBlanket.players.firstIndex(where: { $0.id == playerId }) else {
            throw Abort(.badRequest, reason: "Player not found in away blanket")
        }

        match.awayBlanket?.players.remove(at: index)
        try await match.save(on: req.db)
        return .ok
    }

    // MARK: - Game state

    // PATCH /app/match/:matchID/startGame
    func startGame(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }
        match.status = .first
        match.firstHalfStartDate = Date.viennaNow
        try await match.save(on: req.db)
        return .ok
    }

    // PATCH /app/match/:matchID/endFirstHalf
    func endFirstHalf(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }
        match.status = .halftime
        match.firstHalfEndDate = Date.viennaNow
        try await match.save(on: req.db)
        return .ok
    }

    // PATCH /app/match/:matchID/startSecondHalf
    func startSecondHalf(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }
        match.status = .second
        match.secondHalfStartDate = Date.viennaNow
        try await match.save(on: req.db)
        return .ok
    }

    // PATCH /app/match/:matchID/endGame
    func endGame(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }
        match.status = .completed
        match.secondHalfEndDate = Date.viennaNow
        try await match.save(on: req.db)
        return .ok
    }

    // PATCH /app/match/:matchID/submit
    func completeGame(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct Spielbericht: Content { let text: String? }
        let berichtRequest = try req.content.decode(Spielbericht.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound)
        }

        if match.status != .abbgebrochen {
            match.status = .submitted
        }
        match.bericht = berichtRequest.text

        guard let matchID = match.id, let refID = match.$referee.id else {
            throw Abort(.notFound, reason: "Referee not found")
        }

        let existingStrafsenat = try await Strafsenat.query(on: req.db)
            .filter(\.$match.$id == matchID)
            .first()

        if existingStrafsenat == nil, let text = berichtRequest.text, !text.isEmpty {
            let strafsenat = Strafsenat(matchID: matchID, refID: refID, text: text, offen: true)
            try await strafsenat.save(on: req.db)
        }

        return try await handleMatchCompletion(req: req, match: match, matchID: matchID)
    }

    // PATCH /app/match/:matchID/noShowGame
    func noShowGame(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct NoShowRequest: Content { let winningTeam: String }
        let noShowRequest = try req.content.decode(NoShowRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound)
        }

        let winningTeamId: UUID
        switch noShowRequest.winningTeam.lowercased() {
        case "home":
            match.score = Score(home: 6, away: 0)
            winningTeamId = match.$homeTeam.id
        case "away":
            match.score = Score(home: 0, away: 6)
            winningTeamId = match.$awayTeam.id
        default:
            throw Abort(.badRequest, reason: "Invalid winning team specified")
        }

        match.status = .cancelled
        try await match.save(on: req.db)

        guard let team = try await Team.find(winningTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Winning team not found")
        }
        team.points += 3
        try await team.save(on: req.db)

        return .ok
    }

    // PATCH /app/match/:matchID/teamcancel
    func teamCancelGame(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        struct NoShowRequest: Content { let winningTeam: String }
        let noShowRequest = try req.content.decode(NoShowRequest.self)

        let matchDB = try await Match.query(on: req.db)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$referee) { $0.with(\.$user) }
            .filter(\.$id == matchId)
            .first()

        guard let match = matchDB else { throw Abort(.notFound) }

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
            throw Abort(.badRequest, reason: "Invalid winning team specified")
        }

        match.status = .cancelled
        try await match.save(on: req.db)

        guard let winningTeam = try await Team.find(winningTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Winning team not found")
        }
        guard let losingTeam = try await Team.find(losingTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Losing team not found")
        }

        winningTeam.points += 3

        let cancelled = losingTeam.cancelled ?? 0
        guard cancelled < 3 else {
            throw Abort(.badRequest, reason: "Schon 3 Absagen gemacht diese Saison.")
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
            previousBalance: losingTeam.balance,
            kennzeichen: "Spiel Absage: \(newCancelled)"
        )

        try await rechnung.save(on: req.db)
        losingTeam.balance = balance - Double(rechnungAmount)

        do {
            if let mail = opponentEmail {
                let emailController = EmailController()
                try emailController.sendCancellationNotification(req: req, recipient: mail, match: match)

                if let ref = match.referee, let refUser = ref.user {
                    try emailController.informRefereeCancellation(
                        req: req,
                        email: refUser.email,
                        name: ref.name ?? "Referee",
                        match: match
                    )
                }
            }
        } catch {
            req.logger.warning("Unable to send cancellation emails: \(error)")
        }

        try await losingTeam.save(on: req.db)
        try await winningTeam.save(on: req.db)

        return .ok
    }

    // PATCH /app/match/:matchID/spielabbruch
    func spielabbruch(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }
        match.status = .abbgebrochen
        try await match.save(on: req.db)
        return .ok
    }

    // PATCH /app/match/:matchID/done
    func done(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }

        let homeScore = match.score.home
        let awayScore = match.score.away

        let homeTeam = try await match.$homeTeam.get(on: req.db)
        let awayTeam = try await match.$awayTeam.get(on: req.db)

        if homeScore > awayScore {
            homeTeam.points += 3
        } else if awayScore > homeScore {
            awayTeam.points += 3
        } else {
            homeTeam.points += 1
            awayTeam.points += 1
        }

        try await homeTeam.save(on: req.db)
        try await awayTeam.save(on: req.db)

        match.status = .done
        try await match.save(on: req.db)

        return .ok
    }

    // GET /app/match/:matchID/resetGame
    func resetGame(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }

        match.status = .pending
        match.firstHalfStartDate = nil
        match.secondHalfStartDate = nil
        match.firstHalfEndDate = nil
        match.secondHalfEndDate = nil
        match.score = Score(home: 0, away: 0)

        if var homeBlanket = match.homeBlanket {
            for i in 0..<homeBlanket.players.count {
                homeBlanket.players[i].yellowCard = 0
                homeBlanket.players[i].redYellowCard = 0
                homeBlanket.players[i].redCard = 0
            }
            match.homeBlanket = homeBlanket
        }

        if var awayBlanket = match.awayBlanket {
            for i in 0..<awayBlanket.players.count {
                awayBlanket.players[i].yellowCard = 0
                awayBlanket.players[i].redYellowCard = 0
                awayBlanket.players[i].redCard = 0
            }
            match.awayBlanket = awayBlanket
        }

        try await MatchEvent.query(on: req.db)
            .filter(\.$match.$id == matchId)
            .delete()

        try await match.save(on: req.db)
        return .ok
    }

    // GET /app/match/:matchID/resetHalftime
    func resetHalftime(req: Request) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        guard let match = try await Match.find(matchId, on: req.db) else { throw Abort(.notFound) }

        match.status = .halftime
        match.secondHalfStartDate = nil
        match.secondHalfEndDate = nil

        try await match.save(on: req.db)
        return .ok
    }

    // GET /app/match/league/:matchID  OR  /app/match/:matchID/league
    func getLeagueFromMatch(req: Request) async throws -> League {
        let matchId = try req.parameters.require("matchID", as: UUID.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match with ID \(matchId) not found.")
        }

        guard let seasonID = match.$season.id else {
            throw Abort(.notFound, reason: "Season not found for the match with ID \(matchId).")
        }

        guard let season = try await Season.find(seasonID, on: req.db) else {
            throw Abort(.notFound, reason: "Season with ID \(seasonID) not found.")
        }

        guard let leagueID = season.$league.id else {
            throw Abort(.notFound, reason: "League not found for the season with ID \(seasonID).")
        }

        guard let league = try await League.find(leagueID, on: req.db) else {
            throw Abort(.notFound, reason: "League with ID \(leagueID) not found.")
        }

        return league
    }
    
}

// MARK: - Private helpers
extension AppController {

    private func addCardEvent(req: Request, cardType: MatchEventType) async throws -> HTTPStatus {
        let matchId = try req.parameters.require("matchID", as: UUID.self)
        let cardRequest = try req.content.decode(CardRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }

        if cardRequest.teamId == match.$homeTeam.id {
            updatePlayerCardStatus(in: &match.homeBlanket, playerId: cardRequest.playerId, cardType: cardType)
        } else if cardRequest.teamId == match.$awayTeam.id {
            updatePlayerCardStatus(in: &match.awayBlanket, playerId: cardRequest.playerId, cardType: cardType)
        } else {
            throw Abort(.badRequest, reason: "Team ID does not match home or away team.")
        }

        try await match.save(on: req.db)

        let event = MatchEvent(
            matchId: match.id ?? UUID(),
            type: cardType,
            playerId: cardRequest.playerId,
            minute: cardRequest.minute,
            name: cardRequest.name,
            image: cardRequest.image,
            number: cardRequest.number
        )

        guard let mid = match.id else {
            throw Abort(.internalServerError, reason: "Match ID is missing.")
        }
        event.$match.id = mid

        try await event.save(on: req.db)
        return .ok
    }

    private func handleMatchCompletion(req: Request, match: Match, matchID: UUID) async throws -> HTTPStatus {
        let homeTeam = try await match.$homeTeam.get(on: req.db)
        let league = try await homeTeam.$league.get(on: req.db)

        guard let hourlyRate = league?.hourly else {
            throw Abort(.internalServerError, reason: "Hourly rate not found for league")
        }

        let referee = try await match.$referee.get(on: req.db)
        guard let ref = referee else {
            throw Abort(.notFound, reason: "Referee not found")
        }

        if !(match.paid ?? false) {
            ref.balance = (ref.balance ?? 0) - hourlyRate
            match.paid = true
        }

        try await match.save(on: req.db)
        try await ref.save(on: req.db)

        return .ok
    }
}

extension AppController {

    // MARK: - Public Endpoints

    /// GET /app/match/matchday/:day
    /// Across ALL leagues, but only for seasons marked as `primary == true`.
    func matchesForMatchday(req: Request) async throws -> [AppModels.AppMatchOverview] {
        let day = try req.parameters.require("day", as: Int.self)

        let activeSeasonIDs = try await Season.query(on: req.db)
            .filter(\.$primary == true)
            .all()
            .compactMap(\.id)

        guard !activeSeasonIDs.isEmpty else { return [] }

        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id ~~ activeSeasonIDs)
            .filter(Match.FieldKeys.gameday, .equal, day)
            .all()

        let lookup = try await buildMatchLookup(matches: matches, on: req.db)

        var mapped: [AppModels.AppMatchOverview] = []
        mapped.reserveCapacity(matches.count)

        for m in matches {
            if let ov = try await toAppMatchOverviewSafe(match: m, lookup: lookup, req: req) {
                mapped.append(ov)
            }
        }

        return mapped.sorted { lhs, rhs in
            let lDate = lhs.details.date ?? .distantFuture
            let rDate = rhs.details.date ?? .distantFuture
            if lDate != rDate { return lDate < rDate }

            let lLeague = lhs.season.league
            let rLeague = rhs.season.league
            if lLeague != rLeague { return lLeague < rLeague }

            return lhs.home.name < rhs.home.name
        }
    }

    /// GET /app/match/season/:seasonID/matchday/:day
    /// Matchday for a specific season.
    func matchesForMatchdayForSeason(req: Request) async throws -> [AppModels.AppMatchOverview] {
        let seasonID = try req.parameters.require("seasonID", as: UUID.self)
        let day = try req.parameters.require("day", as: Int.self)

        guard let _ = try await Season.query(on: req.db)
            .filter(\.$id == seasonID)
            .first()
        else {
            throw Abort(.notFound, reason: "Season not found.")
        }

        let matches = try await Match.query(on: req.db)
            .filter(\.$season.$id == seasonID)
            .filter(Match.FieldKeys.gameday, .equal, day)
            .all()

        let lookup = try await buildMatchLookup(matches: matches, on: req.db)

        var mapped: [AppModels.AppMatchOverview] = []
        mapped.reserveCapacity(matches.count)

        for m in matches {
            if let ov = try await toAppMatchOverviewSafe(match: m, lookup: lookup, req: req) {
                mapped.append(ov)
            }
        }

        return mapped.sorted { lhs, rhs in
            let lDate = lhs.details.date ?? .distantFuture
            let rDate = rhs.details.date ?? .distantFuture
            if lDate != rDate { return lDate < rDate }
            return lhs.home.name < rhs.home.name
        }
    }

    // MARK: - Matches For Date (league grouped only)

    /// Matches grouped by league (for the app).
    /// NOTE: intentionally NOT named `LeagueMatches` to avoid colliding with your live score type.
    struct AppLeagueMatches: Content {
        let league: String
        var matches: [AppModels.AppMatchOverview]
    }

    /// GET /app/match/date/:date
    /// `date` must be "yyyy-MM-dd" (no time).
    /// Returns matches on that calendar date across ALL leagues,
    /// but only for seasons marked as `primary == true`.
    ///
    /// Response: league-grouped matches ONLY.
    func matchesForDate(req: Request) async throws -> [AppLeagueMatches] {
        let dateString = try req.parameters.require("date", as: String.self)

        let (targetDate, utcCal) = try parseYMD(dateString)
        let startOfDay = utcCal.startOfDay(for: targetDate)
        guard let startOfNextDay = utcCal.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw Abort(.internalServerError, reason: "Failed to compute day range.")
        }

        let activeSeasonIDs = try await Season.query(on: req.db)
            .filter(\.$primary == true)
            .all()
            .compactMap(\.id)

        guard !activeSeasonIDs.isEmpty else { return [] }

        // Prefer DB-side range on JSON date
        let dbFiltered: [Match] = (try? await Match.query(on: req.db)
            .filter(\.$season.$id ~~ activeSeasonIDs)
            .filter(Match.FieldKeys.date, .greaterThanOrEqual, startOfDay)
            .filter(Match.FieldKeys.date, .lessThan, startOfNextDay)
            .all()
        ) ?? []

        let matchesForThatDate: [Match]
        if !dbFiltered.isEmpty {
            matchesForThatDate = dbFiltered
        } else {
            // Fallback: compare only (year,month,day) in UTC
            let allActive = try await Match.query(on: req.db)
                .filter(\.$season.$id ~~ activeSeasonIDs)
                .all()

            let targetComps = utcCal.dateComponents([.year, .month, .day], from: targetDate)

            matchesForThatDate = allActive.filter { m in
                guard let d = m.details.date else { return false }
                let comps = utcCal.dateComponents([.year, .month, .day], from: d)
                return comps.year == targetComps.year && comps.month == targetComps.month && comps.day == targetComps.day
            }
        }

        let lookup = try await buildMatchLookup(matches: matchesForThatDate, on: req.db)

        var mapped: [AppModels.AppMatchOverview] = []
        mapped.reserveCapacity(matchesForThatDate.count)

        for m in matchesForThatDate {
            if let ov = try await toAppMatchOverviewSafe(match: m, lookup: lookup, req: req) {
                mapped.append(ov)
            }
        }

        // Group by league string and sort
        let grouped = Dictionary(grouping: mapped) { $0.season.league }

        let leagues: [AppLeagueMatches] = grouped
            .map { leagueName, items in
                let sortedMatches = items.sorted { lhs, rhs in
                    let lDate = lhs.details.date ?? .distantFuture
                    let rDate = rhs.details.date ?? .distantFuture
                    if lDate != rDate { return lDate < rDate }
                    return lhs.home.name < rhs.home.name
                }
                return AppLeagueMatches(league: leagueName, matches: sortedMatches)
            }
            .sorted { $0.league.localizedCaseInsensitiveCompare($1.league) == .orderedAscending }

        return leagues
    }

    // MARK: - Available dates endpoint (primary seasons only)

    struct AvailableDatesResponse: Content {
        let dates: [String] // yyyy-MM-dd sorted
    }

    /// GET /app/match/availableDates
    ///
    /// Returns unique yyyy-MM-dd dates that actually have matches,
    /// considering ONLY matches whose season is `primary == true`.
    ///
    /// Optional query params:
    /// - from=yyyy-MM-dd
    /// - to=yyyy-MM-dd (inclusive)
    /// - around=yyyy-MM-dd + windowDays=int (default 180)
    ///
    /// Precedence:
    /// 1) from+to
    /// 2) around(+windowDays)
    /// 3) today(+/-windowDays)
    func availableMatchDates(req: Request) async throws -> AvailableDatesResponse {
        let fromStr = req.query[String.self, at: "from"]
        let toStr = req.query[String.self, at: "to"]
        let aroundStr = req.query[String.self, at: "around"]
        let windowDays = max(1, req.query[Int.self, at: "windowDays"] ?? 180)

        // calendar + parsing helper
        let utcCal = makeUTCCalendar()

        // Determine window [start, end)
        let start: Date
        let endExclusive: Date

        if let fromStr, let toStr {
            let (fromDate, _) = try parseYMD(fromStr)
            let (toDate, _) = try parseYMD(toStr)
            let s = utcCal.startOfDay(for: fromDate)
            // make `to` inclusive by adding 1 day
            guard let e = utcCal.date(byAdding: .day, value: 1, to: utcCal.startOfDay(for: toDate)) else {
                throw Abort(.badRequest, reason: "Invalid to date.")
            }
            start = s
            endExclusive = e
        } else {
            let anchorDate: Date
            if let aroundStr {
                (anchorDate, _) = try parseYMD(aroundStr)
            } else {
                anchorDate = Date()
            }

            let anchorStart = utcCal.startOfDay(for: anchorDate)
            guard
                let s = utcCal.date(byAdding: .day, value: -windowDays, to: anchorStart),
                let e = utcCal.date(byAdding: .day, value: windowDays + 1, to: anchorStart)
            else {
                throw Abort(.internalServerError, reason: "Failed to compute window.")
            }
            start = s
            endExclusive = e
        }

        let activeSeasonIDs = try await Season.query(on: req.db)
            .filter(\.$primary == true)
            .all()
            .compactMap(\.id)

        guard !activeSeasonIDs.isEmpty else {
            return AvailableDatesResponse(dates: [])
        }

        // Prefer DB-side date range
        let dbWindowMatches: [Match] = (try? await Match.query(on: req.db)
            .filter(\.$season.$id ~~ activeSeasonIDs)
            .filter(Match.FieldKeys.date, .greaterThanOrEqual, start)
            .filter(Match.FieldKeys.date, .lessThan, endExclusive)
            .all()
        ) ?? []

        let windowMatches: [Match]
        if !dbWindowMatches.isEmpty {
            windowMatches = dbWindowMatches
        } else {
            // Fallback (still correct, can be heavier)
            windowMatches = try await Match.query(on: req.db)
                .filter(\.$season.$id ~~ activeSeasonIDs)
                .all()
        }

        let dates = uniqueDateStrings(from: windowMatches, utcCal: utcCal)
        return AvailableDatesResponse(dates: dates)
    }

    // MARK: - Safe Mapping (no eager-load)

    private struct MatchLookup {
        let teamsByID: [UUID: Team]
        let seasonsByID: [UUID: Season] // league preloaded
    }

    private func buildMatchLookup(matches: [Match], on db: Database) async throws -> MatchLookup {
        let teamIDs = Array(Set(matches.flatMap { [ $0.$homeTeam.id, $0.$awayTeam.id ] }))
        let seasonIDs = Array(Set(matches.compactMap { $0.$season.id }))

        let teams = try await Team.query(on: db)
            .filter(\.$id ~~ teamIDs)
            .all()

        let seasons = try await Season.query(on: db)
            .filter(\.$id ~~ seasonIDs)
            .with(\.$league)
            .all()

        let teamsByID: [UUID: Team] = Dictionary(uniqueKeysWithValues: teams.compactMap { t in
            guard let id = t.id else { return nil }
            return (id, t)
        })

        let seasonsByID: [UUID: Season] = Dictionary(uniqueKeysWithValues: seasons.compactMap { s in
            guard let id = s.id else { return nil }
            return (id, s)
        })

        return MatchLookup(teamsByID: teamsByID, seasonsByID: seasonsByID)
    }

    /// Converts a `Match` to `AppMatchOverview` without relying on eager-loaded parents.
    /// Returns nil when required references are missing.
    private func toAppMatchOverviewSafe(
        match: Match,
        lookup: MatchLookup,
        req: Request
    ) async throws -> AppModels.AppMatchOverview? {
        guard let matchID = match.id else {
            req.logger.warning("Skipping match without id.")
            return nil
        }

        guard let seasonID = match.$season.id else {
            req.logger.warning("Skipping match \(matchID) because season id is nil.")
            return nil
        }
        guard let season = lookup.seasonsByID[seasonID] else {
            req.logger.warning("Skipping match \(matchID) because season \(seasonID) is missing.")
            return nil
        }
        guard let league = season.league else {
            req.logger.warning("Skipping match \(matchID) because league is missing on season \(seasonID).")
            return nil
        }

        let homeID = match.$homeTeam.id
        let awayID = match.$awayTeam.id

        guard let home = lookup.teamsByID[homeID] else {
            req.logger.warning("Skipping match \(matchID) because home team \(homeID) is missing.")
            return nil
        }
        guard let away = lookup.teamsByID[awayID] else {
            req.logger.warning("Skipping match \(matchID) because away team \(awayID) is missing.")
            return nil
        }

        let leagueOverview = try league.toAppLeagueOverview()
        let appSeason = try season.toAppSeason()

        let homeOverview = AppModels.AppTeamOverview(
            id: try home.requireID(),
            sid: home.sid ?? "",
            league: leagueOverview,
            points: home.points,
            logo: home.logo,
            name: home.teamName,
            shortName: home.shortName,
            stats: nil
        )

        let awayOverview = AppModels.AppTeamOverview(
            id: try away.requireID(),
            sid: away.sid ?? "",
            league: leagueOverview,
            points: away.points,
            logo: away.logo,
            name: away.teamName,
            shortName: away.shortName,
            stats: nil
        )

        let homeMini: MiniBlankett = match.homeBlanket?.toMini()
            ?? Blankett(
                name: home.teamName,
                dress: home.trikot.home,
                logo: home.logo,
                players: [],
                coach: home.coach
            ).toMini()

        let awayMini: MiniBlankett = match.awayBlanket?.toMini()
            ?? Blankett(
                name: away.teamName,
                dress: away.trikot.away,
                logo: away.logo,
                players: [],
                coach: away.coach
            ).toMini()

        return AppModels.AppMatchOverview(
            id: matchID,
            details: match.details,
            score: match.score,
            season: appSeason,
            away: awayOverview,
            home: homeOverview,
            homeBlanket: homeMini,
            awayBlanket: awayMini,
            status: match.status
        )
    }
}

// MARK: - File-private helpers

private func makeUTCCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return cal
}

private func parseYMD(_ ymd: String) throws -> (Date, Calendar) {
    let utcCal = makeUTCCalendar()

    let fmt = DateFormatter()
    fmt.calendar = utcCal
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyy-MM-dd"

    guard let d = fmt.date(from: ymd) else {
        throw Abort(.badRequest, reason: "Invalid date format. Use yyyy-MM-dd.")
    }
    return (d, utcCal)
}

private func uniqueDateStrings(from matches: [Match], utcCal: Calendar) -> [String] {
    var set = Set<String>()
    set.reserveCapacity(matches.count)

    let fmt = DateFormatter()
    fmt.calendar = utcCal
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyy-MM-dd"

    for m in matches {
        guard let d = m.details.date else { continue }
        set.insert(fmt.string(from: d))
    }

    return set.sorted()
}

