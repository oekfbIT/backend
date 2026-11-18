//
//  AdminController+Veo.swift
//  Review of the Veo import.
//
//  GET  /admin/veo/recordings?status=needsReview   list (newest first)
//  POST /admin/veo/recordings/:slug/assign         { "match_id": "…" }  assign manually and re-map events
//

import Foundation
import Vapor
import Fluent

struct AssignVeoRecordingRequest: Content {
    var matchId: UUID   // "match_id" in JSON (global snake_case decoder)
}

extension AdminController {
    func setupVeoRoutes(on root: RoutesBuilder) {
        let veo = root.grouped("veo", "recordings")
        veo.get(use: listVeoRecordings)
        veo.post(":slug", "assign", use: assignVeoRecording)
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
}
