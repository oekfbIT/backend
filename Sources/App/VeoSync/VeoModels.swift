import Foundation
import Fluent
import Vapor

// MARK: - Veo import: one document per Veo recording, plus one per highlight clip.

enum VeoImportStatus: String, Codable {
    case discovered      // seen in the Veo library, nothing imported yet
    case needsReview     // data imported, but match or players could not be assigned automatically
    case matched         // assigned to an ÖKFB match, events mapped
    case videoUploaded   // full recording is on the CDN
    case completed       // clips cut and uploaded
    case failed
}

/// One event as the worker extracted it from Veo (raw) plus what the backend mapped it to.
/// No custom CodingKeys on purpose: the global JSON coders convert snake_case <-> camelCase.
struct VeoEvent: Codable, Equatable {
    // Raw from Veo
    var veoId: String?
    var type: String              // normalised: goal, shot, corner, free_kick, penalty, goal_kick, kickoff, period_start, period_end, yellow_card, red_card, tackle, pass, other
    var veoType: String?          // original label from Veo
    var period: Int?              // 1, 2 …
    var videoSecond: Double       // seconds in the Veo recording (= the file we store)
    var veoTeam: String?          // "home" | "away" (worker normalises Veo's own/opponent using the title order)
    var jerseyNumber: Int?
    var aiDetected: Bool?
    // Mapped by the backend
    var team: MatchAssignment?
    var playerId: UUID?
    var playerName: String?
    var refereeEventId: UUID?

}

final class VeoRecording: Model {
    static let schema = "veo_recordings"

    @ID(key: .id) var id: UUID?
    /// Slug from the Veo URL, e.g. "20261115-bida-united-vs-as-vipers-v3b6395f". Unique.
    @Field(key: "veo_slug") var veoSlug: String
    @Field(key: "title") var title: String
    @OptionalField(key: "recorded_at") var recordedAt: Date?
    @OptionalField(key: "duration_seconds") var durationSeconds: Double?
    @OptionalField(key: "camera_id") var cameraID: String?
    @OptionalField(key: "veo_team") var veoTeam: String?
    @OptionalField(key: "match") var matchID: UUID?
    @Field(key: "status") var status: VeoImportStatus
    @Field(key: "events") var events: [VeoEvent]
    /// Team stats from the Analytics tab, e.g. ["goal": [14, 2], "shot": [14, 9]] (home, away).
    @OptionalField(key: "stats") var stats: [String: [Int]]?
    /// Raw JSON blobs the worker captured (for parsers and debugging). Not exposed publicly.
    @OptionalField(key: "raw") var raw: [String: String]?
    @OptionalField(key: "video_url") var videoURL: String?
    @OptionalField(key: "analytics") var analytics: VeoAnalytics?
    @OptionalField(key: "review_notes") var reviewNotes: [String]?
    @OptionalField(key: "error") var error: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(veoSlug: String, title: String) {
        self.veoSlug = veoSlug
        self.title = title
        self.status = .discovered
        self.events = []
    }
}

final class MatchClip: Model {
    static let schema = "match_clips"

    @ID(key: .id) var id: UUID?
    @Field(key: "match") var matchID: UUID
    @OptionalField(key: "veo_recording") var veoRecordingID: UUID?
    @Field(key: "source") var source: String            // "veo" | "ai" | "manual"
    @Field(key: "type") var type: String
    @Field(key: "event_second") var eventSecond: Double // moment of the event in the full recording
    @Field(key: "start_second") var startSecond: Double // clip start (≈ 10 s before)
    @Field(key: "end_second") var endSecond: Double
    @OptionalField(key: "team") var team: MatchAssignment?
    @OptionalField(key: "player") var playerID: UUID?
    @OptionalField(key: "player_name") var playerName: String?
    @OptionalField(key: "jersey_number") var jerseyNumber: Int?
    @OptionalField(key: "assist_player") var assistPlayerID: UUID?
    @OptionalField(key: "score_after") var scoreAfter: Score?
    @OptionalField(key: "video_url") var videoURL: String?
    @OptionalField(key: "thumbnail_url") var thumbnailURL: String?
    @OptionalField(key: "veo_event_id") var veoEventID: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

// MARK: - API shapes

struct MatchClipResponse: Content {
    let id: UUID?
    let matchID: UUID
    let type: String
    let eventSecond: Double
    let startSecond: Double
    let endSecond: Double
    let team: MatchAssignment?
    let playerID: UUID?
    let playerName: String?
    let jerseyNumber: Int?
    let scoreAfter: Score?
    let videoURL: String?
    let thumbnailURL: String?
    let source: String

    init(_ c: MatchClip) {
        id = c.id; matchID = c.matchID; type = c.type; eventSecond = c.eventSecond; startSecond = c.startSecond
        endSecond = c.endSecond; team = c.team; playerID = c.playerID; playerName = c.playerName
        jerseyNumber = c.jerseyNumber; scoreAfter = c.scoreAfter; videoURL = c.videoURL; thumbnailURL = c.thumbnailURL; source = c.source
    }
}

struct VeoRecordingSummary: Content {
    let id: UUID?
    let veoSlug: String
    let title: String
    let recordedAt: Date?
    let matchID: UUID?
    let status: VeoImportStatus
    let eventCount: Int
    let videoURL: String?
    let reviewNotes: [String]?
    let error: String?

    init(_ r: VeoRecording) {
        id = r.id; veoSlug = r.veoSlug; title = r.title; recordedAt = r.recordedAt; matchID = r.matchID; status = r.status
        eventCount = r.events.count; videoURL = r.videoURL; reviewNotes = r.reviewNotes; error = r.error
    }
}
