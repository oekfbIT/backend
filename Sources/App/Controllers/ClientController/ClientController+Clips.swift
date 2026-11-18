import Foundation
import Vapor
import Fluent

// Public videos for the homepage.
// GET /webClient/match/:matchId/clips          clips of one match (plain)
// GET /webClient/match/:matchId/videos         full recording + clips of one match
// GET /webClient/player/:playerId/clips        clips of one player, with match context
// GET /webClient/team/:id/clips            clips of one team (all its players), with match context
// GET /webClient/videos/league/:code           videos page: recent full matches + clips of a league

/// Minimal match context so a clip card can show "BDU 8:4 AS Vipers · 5. Spieltag".
struct VideoMatchInfo: Content {
    let id: UUID
    let gameday: Int
    let date: Date?
    let homeName: String
    let awayName: String
    let homeLogo: String?
    let awayLogo: String?
    let homeTeamId: UUID
    let awayTeamId: UUID
    let score: Score

    init(_ m: Match) {
        id = m.id ?? UUID(); gameday = m.details.gameday; date = m.details.date
        homeName = m.homeBlanket?.name ?? m.homeTeam.teamName
        awayName = m.awayBlanket?.name ?? m.awayTeam.teamName
        homeLogo = m.homeBlanket?.logo ?? m.homeTeam.logo
        awayLogo = m.awayBlanket?.logo ?? m.awayTeam.logo
        homeTeamId = m.$homeTeam.id; awayTeamId = m.$awayTeam.id
        score = m.score
    }
}

struct VideoClipCard: Content {
    let clip: MatchClipResponse
    let match: VideoMatchInfo?
}

struct MatchVideoCard: Content {
    let match: VideoMatchInfo
    let recordingUrl: String?
    let thumbnailUrl: String?
    let clipCount: Int
}

struct MatchVideosResponse: Content {
    let recordingUrl: String?
    let clips: [MatchClipResponse]
    /// Veo team stats as [home, away], e.g. "goal": [8, 4], "possession_percentage": [59, 41].
    let stats: [String: [Int]]?
    /// Shot map, pass/possession locations, heat maps, physical data.
    let analytics: VeoAnalytics?
}

struct LeagueVideosResponse: Content {
    let matches: [MatchVideoCard]
    let clips: [VideoClipCard]
}

extension ClientController {
    func fetchMatchClips(req: Request) async throws -> [MatchClipResponse] {
        let matchID = try req.parameters.require("matchId", as: UUID.self)
        return try await MatchClip.query(on: req.db).filter(\.$matchID == matchID)
            .sort(\.$eventSecond).all().map { MatchClipResponse($0) }
    }

    func fetchMatchVideos(req: Request) async throws -> MatchVideosResponse {
        let matchID = try req.parameters.require("matchId", as: UUID.self)
        let recording = try await VeoRecording.query(on: req.db).filter(\.$matchID == matchID).first()
        let clips = try await MatchClip.query(on: req.db).filter(\.$matchID == matchID).sort(\.$eventSecond).all()
        return MatchVideosResponse(recordingUrl: recording?.videoURL, clips: clips.map { MatchClipResponse($0) },
                                   stats: recording?.stats, analytics: recording?.analytics)
    }

    func fetchPlayerClips(req: Request) async throws -> [VideoClipCard] {
        let playerID = try req.parameters.require("playerId", as: UUID.self)
        let clips = try await MatchClip.query(on: req.db).filter(\.$playerID == playerID)
            .sort(\.$createdAt, .descending).limit(100).all()
        return try await Self.cards(for: clips, on: req.db)
    }

    func fetchTeamClips(req: Request) async throws -> [VideoClipCard] {
        let teamID = try req.parameters.require("id", as: UUID.self)
        let matches = try await Match.query(on: req.db).group(.or) { $0.filter(\.$homeTeam.$id == teamID).filter(\.$awayTeam.$id == teamID) }.all()
        let sideByMatch = Dictionary(uniqueKeysWithValues: matches.compactMap { m in m.id.map { ($0, m.$homeTeam.id == teamID ? MatchAssignment.home : .away) } })
        guard !sideByMatch.isEmpty else { return [] }
        let clips = try await MatchClip.query(on: req.db).filter(\.$matchID ~~ Array(sideByMatch.keys))
            .sort(\.$createdAt, .descending).limit(400).all()
            .filter { $0.team == sideByMatch[$0.matchID] }
        return try await Self.cards(for: Array(clips.prefix(150)), on: req.db)
    }

    func fetchLeagueVideos(req: Request) async throws -> LeagueVideosResponse {
        guard let code = req.parameters.get("code") else { throw Abort(.badRequest) }
        guard let league = try await League.query(on: req.db).filter(\.$code == code).first(), let leagueID = league.id else {
            throw Abort(.notFound, reason: "Liga nicht gefunden.")
        }
        let teamIDs = try await Team.query(on: req.db).filter(\.$league.$id == leagueID).all().compactMap(\.id)
        guard !teamIDs.isEmpty else { return LeagueVideosResponse(matches: [], clips: []) }

        // Only matches that actually have video.
        let recordings = try await VeoRecording.query(on: req.db).filter(\.$matchID != nil).sort(\.$recordedAt, .descending).limit(300).all()
        let clipMatchIDs = Set(try await MatchClip.query(on: req.db).sort(\.$createdAt, .descending).limit(2000).all().map(\.matchID))
        let candidateIDs = Set(recordings.compactMap(\.matchID)).union(clipMatchIDs)
        guard !candidateIDs.isEmpty else { return LeagueVideosResponse(matches: [], clips: []) }

        let matches = try await Match.query(on: req.db).filter(\.$id ~~ Array(candidateIDs))
            .filter(\.$homeTeam.$id ~~ teamIDs).with(\.$homeTeam).with(\.$awayTeam).all()
        let matchByID = Dictionary(uniqueKeysWithValues: matches.compactMap { m in m.id.map { ($0, m) } })
        let clips = try await MatchClip.query(on: req.db).filter(\.$matchID ~~ Array(matchByID.keys)).all()
        let clipsByMatch = Dictionary(grouping: clips, by: \.matchID)
        let recordingByMatch = Dictionary(recordings.compactMap { r in r.matchID.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })

        let cards = matches.map { m -> MatchVideoCard in
            let id = m.id!
            let firstGoal = clipsByMatch[id]?.sorted { $0.eventSecond < $1.eventSecond }.first { $0.type == "goal" } ?? clipsByMatch[id]?.first
            return MatchVideoCard(match: VideoMatchInfo(m), recordingUrl: recordingByMatch[id]?.videoURL,
                                  thumbnailUrl: firstGoal?.thumbnailURL, clipCount: clipsByMatch[id]?.count ?? 0)
        }.sorted { ($0.match.date ?? .distantPast) > ($1.match.date ?? .distantPast) }

        let clipCards = clips.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(300)
            .map { VideoClipCard(clip: MatchClipResponse($0), match: matchByID[$0.matchID].map(VideoMatchInfo.init)) }
        return LeagueVideosResponse(matches: cards, clips: Array(clipCards))
    }

    static func cards(for clips: [MatchClip], on db: Database) async throws -> [VideoClipCard] {
        let ids = Array(Set(clips.map(\.matchID)))
        guard !ids.isEmpty else { return [] }
        let matches = try await Match.query(on: db).filter(\.$id ~~ ids).with(\.$homeTeam).with(\.$awayTeam).all()
        let byID = Dictionary(uniqueKeysWithValues: matches.compactMap { m in m.id.map { ($0, VideoMatchInfo(m)) } })
        return clips.map { VideoClipCard(clip: MatchClipResponse($0), match: byID[$0.matchID]) }
    }
}
