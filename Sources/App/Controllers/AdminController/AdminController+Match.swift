//
//  AdminController+MatchRoutes.swift
//  oekfbbackend
//
//  Purpose:
//  - Admin Match endpoints (async/await style) similar to AdminController+SeasonRoutes.swift
//  - Only includes the subset you requested + the remaining “game flow” routes (except `done`)
//
//  Mounted under AdminController authed + AdminOnlyMiddleware group.
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Match Routes
extension AdminController {

    func setupMatchRoutes(on root: RoutesBuilder) {
        let matches = root.grouped("matches")

        // CRUD-ish
        matches.post(use: createMatch)
        matches.get(":id", use: getMatchByID)
        matches.patch(":id", use: patchMatch)
        matches.delete(":id", use: deleteMatch)

        // resets
        matches.get(":id", "resetGame", use: resetGame)
        matches.get(":id", "resetHalftime", use: resetHalftime)

        // events / actions
        matches.post(":id", "toggle", use: toggleDress)
        matches.post(":id", "goal", use: addGoal)
        matches.post(":id", "redCard", use: addRedCard)
        matches.post(":id", "yellowCard", use: addYellowCard)
        matches.post(":id", "yellowRedCard", use: addYellowRedCard)

        // blankets
        matches.post(":id", "homeBlankett", "addPlayer", use: addPlayerToHomeBlankett)
        matches.post(":id", "awayBlankett", "addPlayer", use: addPlayerToAwayBlankett)

        matches.delete(":id", ":playerId", "homeBlankett", "removePlayer", use: removePlayerFromHomeBlankett)
        matches.delete(":id", ":playerId", "awayBlankett", "removePlayer", use: removePlayerFromAwayBlankett)

        // game flow (everything except set done)
        matches.patch(":id", "startGame", use: startGame)
        matches.patch(":id", "endFirstHalf", use: endFirstHalf)
        matches.patch(":id", "startSecondHalf", use: startSecondHalf)
        matches.patch(":id", "endGame", use: endGame)

        matches.patch(":id", "submit", use: submitGame)
        matches.patch(":id", "noShowGame", use: noShowGame)
        matches.patch(":id", "teamcancel", use: teamCancelGame)
        matches.patch(":id", "spielabbruch", use: spielabbruch)
        // GET /admin/matches/:id/referee
        matches.get(":id", "referee", use: getMatchReferee)

    }
}

// MARK: - DTOs
extension AdminController {

    struct CreateMatchRequest: Content {
        let seasonId: UUID
        let homeTeamId: UUID
        let awayTeamId: UUID
        let gameday: Int

        // optional admin-decided fields
        let date: Date?
        let stadiumId: UUID?
        let location: String?

        // optional: override dresses (else use team trikot)
        let homeDress: String?
        let awayDress: String?

        // optional
        let status: GameStatus?
    }

    struct ToggleDressRequest: Content {
        let team: String // "home" | "away"
    }

    struct GoalRequest: Content {
        let playerId: UUID
        let scoreTeam: String // "home" | "away"
        let minute: Int
        let name: String?
        let image: String?
        let number: String?
        let assign: MatchAssignment?
        let ownGoal: Bool?
    }

    struct CardRequest: Content {
        let playerId: UUID
        let teamId: UUID
        let minute: Int
        let name: String?
        let image: String?
        let number: String?
    }

    struct AddPlayerToBlankettRequest: Content {
        let playerId: UUID
        let number: Int
        let coach: Trainer?
    }

    struct SubmitGameRequest: Content {
        let text: String?
    }

    struct NoShowRequest: Content {
        let winningTeam: String // "home" | "away"
    }
}

// MARK: - Handlers
extension AdminController {

    // MARK: POST /admin/matches
    func createMatch(req: Request) async throws -> Match {
        let body = try req.content.decode(CreateMatchRequest.self)

        guard body.gameday >= 0 else {
            throw Abort(.badRequest, reason: "gameday must be >= 0.")
        }
        guard body.homeTeamId != body.awayTeamId else {
            throw Abort(.badRequest, reason: "Home and away team cannot be the same.")
        }

        guard let season = try await Season.find(body.seasonId, on: req.db) else {
            throw Abort(.notFound, reason: "Season not found.")
        }
        let seasonId = try season.requireID()

        guard let homeTeam = try await Team.find(body.homeTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Home team not found.")
        }
        guard let awayTeam = try await Team.find(body.awayTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Away team not found.")
        }

        // optional stadium validation
        if let sid = body.stadiumId, (try await Stadium.find(sid, on: req.db)) == nil {
            throw Abort(.notFound, reason: "Stadium not found.")
        }

        let details = MatchDetails(
            gameday: body.gameday,
            date: body.date,
            stadium: body.stadiumId,
            location: (body.location?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        )

        let homeBlanket = Blankett(
            name: homeTeam.teamName,
            dress: body.homeDress ?? homeTeam.trikot.home,
            logo: homeTeam.logo,
            players: [],
            coach: homeTeam.coach
        )

        let awayBlanket = Blankett(
            name: awayTeam.teamName,
            dress: body.awayDress ?? awayTeam.trikot.away,
            logo: awayTeam.logo,
            players: [],
            coach: awayTeam.coach
        )

        let match = Match(
            details: details,
            homeTeamId: try homeTeam.requireID(),
            awayTeamId: try awayTeam.requireID(),
            homeBlanket: homeBlanket,
            awayBlanket: awayBlanket,
            score: Score(home: 0, away: 0),
            status: body.status ?? .pending
        )
        match.$season.id = seasonId

        try await match.save(on: req.db)
        return match
    }

    // MARK: GET /admin/matches/:id
    func getMatchByID(req: Request) async throws -> Match {
        let match = try await requireMatch(req: req, param: "id")
        // load events so admin UI can show timeline immediately
        try await match.$events.load(on: req.db)
        return match
    }

    // MARK: PATCH /admin/matches/:id
    func patchMatch(req: Request) async throws -> Match {
        let id = try requireUUIDParam(req, "id")

        let updatedItem: Match
        do {
            updatedItem = try req.content.decode(Match.self)
        } catch {
            throw Abort(.badRequest, reason: "Invalid JSON payload.")
        }

        guard let existing = try await Match.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found.")
        }

        let merged = existing.merge(from: updatedItem)
        try await merged.update(on: req.db)
        return merged
    }

    // MARK: DELETE /admin/matches/:id
    func deleteMatch(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatch(req: req, param: "id")
        let matchId = try match.requireID()

        // delete children events first (keeps DB clean)
        _ = try await MatchEvent.query(on: req.db)
            .filter(\.$match.$id == matchId)
            .delete()

        try await match.delete(on: req.db)
        return .noContent
    }

    // MARK: GET /admin/matches/:id/resetGame
    func resetGame(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatch(req: req, param: "id")
        let matchId = try match.requireID()

        match.status = .pending
        match.firstHalfStartDate = nil
        match.secondHalfStartDate = nil
        match.firstHalfEndDate = nil
        match.secondHalfEndDate = nil
        match.score = Score(home: 0, away: 0)

        if var homeBlanket = match.homeBlanket {
            for i in homeBlanket.players.indices {
                homeBlanket.players[i].yellowCard = 0
                homeBlanket.players[i].redYellowCard = 0
                homeBlanket.players[i].redCard = 0
            }
            match.homeBlanket = homeBlanket
        }

        if var awayBlanket = match.awayBlanket {
            for i in awayBlanket.players.indices {
                awayBlanket.players[i].yellowCard = 0
                awayBlanket.players[i].redYellowCard = 0
                awayBlanket.players[i].redCard = 0
            }
            match.awayBlanket = awayBlanket
        }

        _ = try await MatchEvent.query(on: req.db)
            .filter(\.$match.$id == matchId)
            .delete()

        try await match.save(on: req.db)
        return .ok
    }

    // MARK: GET /admin/matches/:id/resetHalftime
    func resetHalftime(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatch(req: req, param: "id")
        match.status = .halftime
        match.secondHalfStartDate = nil
        match.secondHalfEndDate = nil
        try await match.save(on: req.db)
        return .ok
    }

    // MARK: POST /admin/matches/:id/toggle
    func toggleDress(req: Request) async throws -> HTTPStatus {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(ToggleDressRequest.self)

        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }

        switch body.team.lowercased() {
        case "home":
            guard let homeBlanket = match.homeBlanket else {
                throw Abort(.badRequest, reason: "Home blanket not found")
            }
            if homeBlanket.dress == match.homeTeam.trikot.home {
                match.homeBlanket?.dress = match.homeTeam.trikot.away
            } else {
                match.homeBlanket?.dress = match.homeTeam.trikot.home
            }

        case "away":
            guard let awayBlanket = match.awayBlanket else {
                throw Abort(.badRequest, reason: "Away blanket not found")
            }
            if awayBlanket.dress == match.awayTeam.trikot.home {
                match.awayBlanket?.dress = match.awayTeam.trikot.away
            } else {
                match.awayBlanket?.dress = match.awayTeam.trikot.home
            }

        default:
            throw Abort(.badRequest, reason: "Invalid team specified. Must be 'home' or 'away'.")
        }

        try await match.save(on: req.db)
        return .ok
    }

    // MARK: POST /admin/matches/:id/goal
    func addGoal(req: Request) async throws -> HTTPStatus {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(GoalRequest.self)

        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }

        switch body.scoreTeam.lowercased() {
        case "home": match.score.home += 1
        case "away": match.score.away += 1
        default: throw Abort(.badRequest, reason: "Invalid team specified")
        }

        try await match.save(on: req.db)

        let event = MatchEvent(
            matchId: matchId,
            type: .goal,
            playerId: body.playerId,
            minute: body.minute,
            name: body.name,
            image: body.image,
            number: body.number,
            assign: body.assign,
            ownGoal: body.ownGoal
        )
        event.$match.id = matchId
        try await event.save(on: req.db)

        _ = MatchPushNotifier.fire(.goal, match: match, req: req, extra: [
            "minute": String(body.minute),
            "playerName": body.name ?? "",
            "playerNumber": body.number ?? "",
            "playerId": body.playerId.uuidString,
            "teamSide": body.scoreTeam.lowercased()
        ])

        return .created
    }

    // MARK: POST /admin/matches/:id/redCard
    func addRedCard(req: Request) async throws -> HTTPStatus {
        try await addCard(req: req, cardType: .redCard)
        return .ok
    }

    // MARK: POST /admin/matches/:id/yellowCard
    func addYellowCard(req: Request) async throws -> HTTPStatus {
        try await addCard(req: req, cardType: .yellowCard)
        return .ok
    }

    // MARK: POST /admin/matches/:id/yellowRedCard
    func addYellowRedCard(req: Request) async throws -> HTTPStatus {
        try await addCard(req: req, cardType: .yellowRedCard)
        return .ok
    }

    // MARK: POST /admin/matches/:id/homeBlankett/addPlayer
    func addPlayerToHomeBlankett(req: Request) async throws -> HTTPStatus {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(AddPlayerToBlankettRequest.self)

        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$homeTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }

        guard let player = try await Player.find(body.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found")
        }
        guard let pid = player.id else {
            throw Abort(.internalServerError, reason: "Player ID missing")
        }

        if match.homeBlanket == nil {
            match.homeBlanket = Blankett(
                name: match.homeTeam.teamName,
                dress: match.homeTeam.trikot.home,
                logo: match.homeTeam.logo,
                players: [],
                coach: body.coach
            )
        } else if body.coach != nil {
            match.homeBlanket?.coach = body.coach
        }

        if (match.homeBlanket?.players.count ?? 0) >= 12 {
            throw Abort(.conflict, reason: "Home team already has 12 players.")
        }

        if let idx = match.homeBlanket?.players.firstIndex(where: { $0.id == pid }) {
            match.homeBlanket?.players[idx].number = body.number
        } else {
            match.homeBlanket?.players.append(
                PlayerOverview(
                    id: pid,
                    sid: player.sid,
                    name: player.name,
                    number: body.number,
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

    // MARK: POST /admin/matches/:id/awayBlankett/addPlayer
    func addPlayerToAwayBlankett(req: Request) async throws -> HTTPStatus {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(AddPlayerToBlankettRequest.self)

        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$awayTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }

        guard let player = try await Player.find(body.playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found")
        }
        guard let pid = player.id else {
            throw Abort(.internalServerError, reason: "Player ID missing")
        }

        if match.awayBlanket == nil {
            match.awayBlanket = Blankett(
                name: match.awayTeam.teamName,
                dress: match.awayTeam.trikot.away,
                logo: match.awayTeam.logo,
                players: [],
                coach: body.coach
            )
        } else if body.coach != nil {
            match.awayBlanket?.coach = body.coach
        }

        if (match.awayBlanket?.players.count ?? 0) >= 12 {
            throw Abort(.conflict, reason: "Away team already has 12 players.")
        }

        if let idx = match.awayBlanket?.players.firstIndex(where: { $0.id == pid }) {
            match.awayBlanket?.players[idx].number = body.number
        } else {
            match.awayBlanket?.players.append(
                PlayerOverview(
                    id: pid,
                    sid: player.sid,
                    name: player.name,
                    number: body.number,
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

    // MARK: DELETE /admin/matches/:id/:playerId/homeBlankett/removePlayer
    func removePlayerFromHomeBlankett(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatch(req: req, param: "id")
        let playerId = try requireUUIDParam(req, "playerId")

        guard let home = match.homeBlanket else {
            throw Abort(.badRequest, reason: "Home blanket not found")
        }

        guard let idx = home.players.firstIndex(where: { $0.id == playerId }) else {
            throw Abort(.badRequest, reason: "Player not found in home blanket")
        }

        match.homeBlanket?.players.remove(at: idx)
        try await match.save(on: req.db)
        return .ok
    }

    // MARK: DELETE /admin/matches/:id/:playerId/awayBlankett/removePlayer
    func removePlayerFromAwayBlankett(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatch(req: req, param: "id")
        let playerId = try requireUUIDParam(req, "playerId")

        guard let away = match.awayBlanket else {
            throw Abort(.badRequest, reason: "Away blanket not found")
        }

        guard let idx = away.players.firstIndex(where: { $0.id == playerId }) else {
            throw Abort(.badRequest, reason: "Player not found in away blanket")
        }

        match.awayBlanket?.players.remove(at: idx)
        try await match.save(on: req.db)
        return .ok
    }

    // MARK: PATCH /admin/matches/:id/startGame
    func startGame(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatchWithTeams(req)
        match.status = .first
        match.firstHalfStartDate = Date.viennaNow
        try await match.save(on: req.db)
        _ = MatchPushNotifier.fire(.gameStarted, match: match, req: req)
        return .ok
    }

    // MARK: PATCH /admin/matches/:id/endFirstHalf
    func endFirstHalf(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatchWithTeams(req)
        match.status = .halftime
        match.firstHalfEndDate = Date.viennaNow
        try await match.save(on: req.db)
        _ = MatchPushNotifier.fire(.halftime, match: match, req: req)
        return .ok
    }

    // MARK: PATCH /admin/matches/:id/startSecondHalf
    func startSecondHalf(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatchWithTeams(req)
        match.status = .second
        match.secondHalfStartDate = Date.viennaNow
        try await match.save(on: req.db)
        _ = MatchPushNotifier.fire(.secondHalfStarted, match: match, req: req)
        return .ok
    }

    // MARK: PATCH /admin/matches/:id/endGame
    func endGame(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatchWithTeams(req)
        match.status = .completed
        match.secondHalfEndDate = Date.viennaNow
        try await match.save(on: req.db)
        _ = MatchPushNotifier.fire(.gameEnded, match: match, req: req)
        return .ok
    }

    // MARK: PATCH /admin/matches/:id/submit
    func submitGame(req: Request) async throws -> HTTPStatus {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(SubmitGameRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }

        if match.status != .abbgebrochen {
            match.status = .submitted
        }
        match.bericht = body.text

        try await match.save(on: req.db)
        return .ok
    }

    // MARK: PATCH /admin/matches/:id/noShowGame
    func noShowGame(req: Request) async throws -> HTTPStatus {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(NoShowRequest.self)

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found")
        }

        let winningTeamId: UUID
        switch body.winningTeam.lowercased() {
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

    // MARK: PATCH /admin/matches/:id/teamcancel
    func teamCancelGame(req: Request) async throws -> HTTPStatus {
        // Keeping this as a stub in admin controller because your legacy version has:
        // - emails
        // - points updates
        // - cancellation tracking
        // - Rechnung creation
        //
        // If you want the full logic copied 1:1 into admin, tell me and I’ll port it cleanly.
        throw Abort(.notImplemented, reason: "teamcancel not yet ported to AdminController+MatchRoutes.swift")
    }

    // MARK: PATCH /admin/matches/:id/spielabbruch
    func spielabbruch(req: Request) async throws -> HTTPStatus {
        let match = try await requireMatch(req: req, param: "id")
        match.status = .abbgebrochen
        try await match.save(on: req.db)
        return .ok
    }
    
    // MARK: GET /admin/matches/:id/referee
    struct MatchRefereeResponse: Content {
        let assigned: Bool
        let referee: Referee?
    }

    func getMatchReferee(req: Request) async throws -> MatchRefereeResponse {
        guard let matchId = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid match ID.")
        }

        guard let match = try await Match.find(matchId, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found.")
        }

        guard let refereeId = match.$referee.id else {
            return MatchRefereeResponse(assigned: false, referee: nil)
        }

        let referee = try await Referee.find(refereeId, on: req.db)
        return MatchRefereeResponse(assigned: referee != nil, referee: referee)
    }

}

// MARK: - Internals (cards)
private extension AdminController {

    func addCard(req: Request, cardType: MatchEventType) async throws {
        let matchId = try requireUUIDParam(req, "id")
        let body = try req.content.decode(CardRequest.self)

        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == matchId)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }

        // Determine side + update blanket counters
        let side: String
        if body.teamId == match.$homeTeam.id {
            side = "home"
            adminupdatePlayerCardStatus(in: &match.homeBlanket, playerId: body.playerId, cardType: cardType)
        } else if body.teamId == match.$awayTeam.id {
            side = "away"
            adminupdatePlayerCardStatus(in: &match.awayBlanket, playerId: body.playerId, cardType: cardType)
        } else {
            throw Abort(.badRequest, reason: "Team ID does not match home or away team.")
        }

        try await match.save(on: req.db)

        let event = MatchEvent(
            matchId: matchId,
            type: cardType,
            playerId: body.playerId,
            minute: body.minute,
            name: body.name,
            image: body.image,
            number: body.number
        )
        event.$match.id = matchId
        try await event.create(on: req.db)

        // push mapping
        let pushEvent: MatchPushNotifier.Event? = {
            switch cardType {
            case .redCard: return .redCard
            case .yellowCard: return .yellowCard
            case .yellowRedCard: return .yellowRedCard
            default: return nil
            }
        }()

        if let pushEvent {
            _ = MatchPushNotifier.fire(pushEvent, match: match, req: req, extra: [
                "minute": String(body.minute),
                "playerName": body.name ?? "",
                "playerNumber": body.number ?? "",
                "playerId": body.playerId.uuidString,
                "teamSide": side
            ])
        }
    }
}

// MARK: - Helpers
private extension AdminController {

    func requireUUIDParam(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid \(name).")
        }
        return id
    }

    func requireMatch(req: Request, param: String) async throws -> Match {
        let id = try requireUUIDParam(req, param)
        guard let match = try await Match.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Match not found.")
        }
        return match
    }

    func requireMatchWithTeams(_ req: Request) async throws -> Match {
        let id = try requireUUIDParam(req, "id")
        guard let match = try await Match.query(on: req.db)
            .filter(\.$id == id)
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .first()
        else { throw Abort(.notFound, reason: "Match not found") }
        return match
    }
}

// MARK: - Shared helper (same as your legacy controller)
private func adminupdatePlayerCardStatus(in blanket: inout Blankett?, playerId: UUID, cardType: MatchEventType) {
    guard blanket != nil else { return }

    if let index = blanket!.players.firstIndex(where: { $0.id == playerId }) {
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
