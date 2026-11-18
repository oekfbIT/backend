import Foundation
import Fluent
import Vapor

/// Endpoints for the Veo Sync worker (tools/veo-sync). Secured with VEO_SYNC_SERVICE_KEY
/// in the "X-Veo-Sync-Key" header.
///
/// GET  /veo-sync/known                         → slugs already in the database (worker skips completed ones)
/// POST /veo-sync/recordings                    → upsert recording + events + stats, match + map, returns summary
/// POST /veo-sync/recordings/:slug/video        → CDN URL of the full recording
/// POST /veo-sync/recordings/:slug/clips        → clips the worker cut and uploaded
struct VeoSyncController: RouteCollection {

    struct ServiceKeyMiddleware: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            let expected = Environment.get("VEO_SYNC_SERVICE_KEY") ?? ""
            let given = request.headers.first(name: "X-Veo-Sync-Key") ?? ""
            guard !expected.isEmpty, given.count == expected.count,
                  zip(given.utf8, expected.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
                throw Abort(.unauthorized)
            }
            return try await next.respond(to: request)
        }
    }

    // Global JSON decoder converts snake_case → camelCase, so property names are camelCase without CodingKeys.
    struct RecordingUpsert: Content {
        var veoSlug: String
        var title: String
        var recordedAt: Date?
        var durationSeconds: Double?
        var cameraId: String?
        var veoTeam: String?
        var events: [VeoEvent]
        var stats: [String: [Int]]?
        var raw: [String: String]?
        /// Set when the run was started for a specific match from the admin.
        var matchId: UUID?
    }
    struct MatchInfo: Content { let matchId: UUID; let date: Date?; let homeName: String; let awayName: String }
    struct VideoUpdate: Content { var videoUrl: String }
    struct ClipUpsert: Content {
        var veoEventId: String?
        var type: String
        var eventSecond: Double
        var startSecond: Double
        var endSecond: Double
        var videoUrl: String
        var thumbnailUrl: String?
    }
    struct KnownRecording: Content { let veoSlug: String; let status: VeoImportStatus; let hasVideo: Bool }

    func boot(routes: RoutesBuilder) throws {
        let sync = routes.grouped("veo-sync").grouped(ServiceKeyMiddleware())
        sync.get("known", use: known)
        sync.get("match", ":id", use: matchInfo)
        sync.on(.POST, "recordings", body: .collect(maxSize: "10mb"), use: upsertRecording)
        sync.post("recordings", ":slug", "video", use: setVideo)
        sync.post("recordings", ":slug", "clips", use: addClips)
    }

    func known(req: Request) async throws -> [KnownRecording] {
        try await VeoRecording.query(on: req.db).all()
            .map { KnownRecording(veoSlug: $0.veoSlug, status: $0.status, hasVideo: $0.videoURL != nil) }
    }

    /// Date and team names of one ÖKFB match, so the worker can find it in the Veo library.
    func matchInfo(req: Request) async throws -> MatchInfo {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let match = try await Match.query(on: req.db).filter(\.$id == id).with(\.$homeTeam).with(\.$awayTeam).first() else {
            throw Abort(.notFound, reason: "Spiel nicht gefunden.")
        }
        return MatchInfo(matchId: id, date: match.details.date,
                         homeName: match.homeBlanket?.name ?? match.homeTeam.teamName,
                         awayName: match.awayBlanket?.name ?? match.awayTeam.teamName)
    }

    func upsertRecording(req: Request) async throws -> VeoRecordingSummary {
        let body = try req.content.decode(RecordingUpsert.self)
        let recording = try await VeoRecording.query(on: req.db).filter(\.$veoSlug == body.veoSlug).first()
            ?? VeoRecording(veoSlug: body.veoSlug, title: body.title)
        recording.title = body.title
        recording.recordedAt = body.recordedAt
        recording.durationSeconds = body.durationSeconds
        recording.cameraID = body.cameraId
        recording.veoTeam = body.veoTeam
        recording.stats = body.stats
        recording.raw = body.raw
        recording.events = body.events.sorted { $0.videoSecond < $1.videoSecond }
        try await Self.assign(recording, to: body.matchId, on: req.db)
        return VeoRecordingSummary(recording)
    }

    func setVideo(req: Request) async throws -> VeoRecordingSummary {
        let recording = try await Self.recording(req)
        recording.videoURL = try req.content.decode(VideoUpdate.self).videoUrl
        if recording.status == .matched { recording.status = .videoUploaded }
        try await recording.save(on: req.db)
        return VeoRecordingSummary(recording)
    }

    func addClips(req: Request) async throws -> [MatchClipResponse] {
        let recording = try await Self.recording(req)
        guard let matchID = recording.matchID else { throw Abort(.conflict, reason: "Aufnahme ist noch keinem Spiel zugeordnet.") }
        let clips = try req.content.decode([ClipUpsert].self)
        let recordingID = try recording.requireID()

        // Replace earlier clips of this recording (re-runs are idempotent).
        try await MatchClip.query(on: req.db).filter(\.$veoRecordingID == recordingID).delete()

        // Running score for goal clips.
        var home = 0, away = 0
        var scoreByEvent: [String: Score] = [:]
        for event in recording.events where event.type == "goal" {
            if event.team == .home { home += 1 } else if event.team == .away { away += 1 }
            if let id = event.veoId { scoreByEvent[id] = Score(home: home, away: away) }
        }

        var saved: [MatchClip] = []
        for c in clips {
            let event = c.veoEventId.flatMap { id in recording.events.first { $0.veoId == id } }
            let clip = MatchClip()
            clip.matchID = matchID
            clip.veoRecordingID = recordingID
            clip.source = "veo"
            clip.type = c.type
            clip.eventSecond = c.eventSecond
            clip.startSecond = c.startSecond
            clip.endSecond = c.endSecond
            clip.team = event?.team
            clip.playerID = event?.playerId
            clip.playerName = event?.playerName
            clip.jerseyNumber = event?.jerseyNumber
            clip.scoreAfter = c.veoEventId.flatMap { scoreByEvent[$0] }
            clip.videoURL = c.videoUrl
            clip.thumbnailURL = c.thumbnailUrl
            clip.veoEventID = c.veoEventId
            try await clip.save(on: req.db)
            saved.append(clip)
        }
        if recording.status != .needsReview { recording.status = .completed }
        try await recording.save(on: req.db)
        return saved.map { MatchClipResponse($0) }
    }

    // MARK: - Shared

    static func recording(_ req: Request) async throws -> VeoRecording {
        let slug = try req.parameters.require("slug")
        guard let recording = try await VeoRecording.query(on: req.db).filter(\.$veoSlug == slug).first() else {
            throw Abort(.notFound, reason: "Veo-Aufnahme \(slug) unbekannt.")
        }
        return recording
    }

    /// Match (automatic or forced by an admin), map teams/players, link referee events, set status.
    static func assign(_ recording: VeoRecording, to forcedMatchID: UUID?, on db: Database) async throws {
        var notes: [String] = []
        var match: Match?
        var swapped = false
        if let forcedMatchID {
            match = try await Match.find(forcedMatchID, on: db)
            if let names = VeoMatcher.teams(fromTitle: recording.title), let m = match {
                let homeName = m.homeBlanket?.name ?? ""
                swapped = VeoMatcher.similarity(homeName, names.away) > VeoMatcher.similarity(homeName, names.home)
            }
        } else {
            let result = try await VeoMatcher.findMatch(title: recording.title, recordedAt: recording.recordedAt, on: db)
            match = result.match; swapped = result.swapped; notes += result.notes
        }
        if let match, let matchID = match.id {
            let mapped = VeoMatcher.mapEvents(recording.events, match: match, swapped: swapped)
            recording.events = try await VeoMatcher.linkRefereeEvents(mapped.events, matchID: matchID, on: db)
            notes += mapped.notes
            recording.matchID = matchID
            recording.status = notes.isEmpty ? (recording.videoURL == nil ? .matched : .videoUploaded) : .needsReview
        } else {
            recording.matchID = nil
            recording.status = .needsReview
        }
        recording.reviewNotes = notes.isEmpty ? nil : notes
        recording.error = nil
        try await recording.save(on: db)
    }
}
