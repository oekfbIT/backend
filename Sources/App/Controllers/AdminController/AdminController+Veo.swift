//
//  AdminController+Veo.swift
//
//  GET  /admin/matches/:id/veo                 recording linked to the match, latest sync job, clip count
//  POST /admin/matches/:id/veo/sync            { "veo_url": optional link/slug, "with_video": true }  start worker
//  GET  /admin/veo/recordings?status=…         import review list
//  POST /admin/veo/recordings/:slug/assign     { "match_id": "…" }
//

import Foundation
import Vapor
import Fluent

struct AssignVeoRecordingRequest: Content {
    var matchId: UUID   // "match_id" (global snake_case decoder)
}

struct StartVeoSyncRequest: Content {
    var veoUrl: String?
    var withVideo: Bool?
}

struct MatchVeoStatus: Content {
    let recording: VeoRecordingSummary?
    let job: VeoSyncJobResponse?
    let clipCount: Int
}

extension AdminController {
    func setupVeoRoutes(on root: RoutesBuilder) {
        let veo = root.grouped("veo", "recordings")
        veo.get(use: listVeoRecordings)
        veo.post(":slug", "assign", use: assignVeoRecording)

        let match = root.grouped("matches", ":id", "veo")
        match.get(use: matchVeoStatus)
        match.post("sync", use: startMatchVeoSync)
    }

    func listVeoRecordings(req: Request) async throws -> [VeoRecordingSummary] {
        var query = VeoRecording.query(on: req.db).sort(\.$recordedAt, .descending).limit(200)
        if let status = req.query[String.self, at: "status"].flatMap(VeoImportStatus.init(rawValue:)) {
            query = query.filter(\.$status == status)
        }
        return try await query.all().map { VeoRecordingSummary($0) }
    }

    func assignVeoRecording(req: Request) async throws -> VeoRecordingSummary {
        let recording = try await VeoSyncController.recording(req)
        let body = try req.content.decode(AssignVeoRecordingRequest.self)
        try await VeoSyncController.assign(recording, to: body.matchId, on: req.db)
        return VeoRecordingSummary(recording)
    }

    func matchVeoStatus(req: Request) async throws -> MatchVeoStatus {
        let matchID = try req.parameters.require("id", as: UUID.self)
        let recording = try await VeoRecording.query(on: req.db).filter(\.$matchID == matchID).first()
        let job = try await VeoSyncJob.query(on: req.db).filter(\.$matchID == matchID).sort(\.$createdAt, .descending).first()
        if let job, ["running", "queued"].contains(job.status), let updated = job.updatedAt ?? job.createdAt, Date().timeIntervalSince(updated) > 1800 {
            let wasQueued = job.status == "queued"
            job.status = "failed"
            job.log.append(wasQueued ? "✗ Kein Worker hat den Auftrag übernommen (läuft der Veo-Worker?)" : "✗ Keine Rückmeldung mehr (Worker neu gestartet?)")
            try await job.save(on: req.db)
        }
        let clips = try await MatchClip.query(on: req.db).filter(\.$matchID == matchID).count()
        return MatchVeoStatus(recording: recording.map { VeoRecordingSummary($0) }, job: job.map { VeoSyncJobResponse($0) }, clipCount: clips)
    }

    func startMatchVeoSync(req: Request) async throws -> MatchVeoStatus {
        let matchID = try req.parameters.require("id", as: UUID.self)
        guard try await Match.find(matchID, on: req.db) != nil else { throw Abort(.notFound, reason: "Spiel nicht gefunden.") }
        if let running = try await VeoSyncJob.query(on: req.db).filter(\.$matchID == matchID).filter(\.$status ~~ ["running", "queued"]).first(),
           let updated = running.updatedAt ?? running.createdAt, Date().timeIntervalSince(updated) < 1800 {
            throw Abort(.conflict, reason: "Für dieses Spiel läuft bereits ein Veo-Import.")
        }
        let body = (try? req.content.decode(StartVeoSyncRequest.self)) ?? StartVeoSyncRequest()
        // Accept a full link (…/matches/<slug>/) or the bare slug.
        var slug: String? = nil
        if let text = body.veoUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let range = text.range(of: #"/matches/[^/?#]+"#, options: .regularExpression) {
                slug = String(text[range].dropFirst("/matches/".count))
            } else {
                slug = text
            }
        }
        let job = VeoSyncJob(matchID: matchID, veoSlug: slug, withVideo: body.withVideo ?? true)
        if VeoSyncMode.isQueue {
            job.status = "queued"
            job.log = ["In Warteschlange – der Veo-Worker übernimmt in Kürze…"]
            try await job.save(on: req.db)
            return try await matchVeoStatus(req: req)
        }
        try await job.save(on: req.db)
        do {
            try VeoSyncRunner.start(job: job, app: req.application)
        } catch {
            job.status = "failed"; job.log = ["✗ \(error)"]
            try await job.save(on: req.db)
        }
        return try await matchVeoStatus(req: req)
    }
}
