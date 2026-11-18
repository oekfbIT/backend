import Foundation
import Vapor
import Fluent

// Public highlight clips for the homepage (match page, player page popups).
// GET /webClient/match/:matchId/clips
// GET /webClient/player/:playerId/clips
extension ClientController {
    func fetchMatchClips(req: Request) async throws -> [MatchClipResponse] {
        let matchID = try req.parameters.require("matchId", as: UUID.self)
        return try await MatchClip.query(on: req.db).filter(\.$matchID == matchID)
            .sort(\.$eventSecond).all().map { MatchClipResponse($0) }
    }

    func fetchPlayerClips(req: Request) async throws -> [MatchClipResponse] {
        let playerID = try req.parameters.require("playerId", as: UUID.self)
        return try await MatchClip.query(on: req.db).filter(\.$playerID == playerID)
            .sort(\.$createdAt, .descending).limit(100).all().map { MatchClipResponse($0) }
    }
}
