//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 04.12.25.
//

import Foundation
import Vapor

struct FCMConfig {
    let serverKey: String
    let endpoint: URI

    static func fromEnv(_ app: Application) -> FCMConfig {
        let key = Environment.get("FCM_SERVER_KEY") ?? "FCM_SERVER_KEY_DEV_PLACEHOLDER"
        if Environment.get("FCM_SERVER_KEY") == nil {
            app.logger.warning("FCM_SERVER_KEY not set. Using DEV placeholder; real FCM pushes will fail.")
        }

        return FCMConfig(
            serverKey: key,
            endpoint: URI(string: "https://fcm.googleapis.com/fcm/send")
        )
    }
}

struct FCMPayload: Content {
    struct Notification: Content {
        let title: String
        let body: String
    }

    /// Multiple tokens at once
    let registration_ids: [String]
    let notification: Notification
    let data: [String: String]?
}

/// Thin wrapper for sending push notifications via FCM (legacy HTTP API).
struct FCMService {
    /// Send a push notification to a list of FCM tokens.
    static func send(
        to tokens: [String],
        title: String,
        body: String,
        data: [String: String] = [:],
        req: Request
    ) async throws {
        guard !tokens.isEmpty else {
            req.logger.debug("FCMService.send called with 0 tokens; skipping.")
            return
        }

        let config = FCMConfig.fromEnv(req.application)

        let payload = FCMPayload(
            registration_ids: tokens,
            notification: .init(title: title, body: body),
            data: data.isEmpty ? nil : data
        )

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "key=\(config.serverKey)")
        headers.add(name: .contentType, value: "application/json")

        let response = try await req.client.post(config.endpoint, headers: headers) { clientReq in
            try clientReq.content.encode(payload, as: .json)
        }

        if response.status != .ok {
            let bodyString = response.body.flatMap { String(buffer: $0) } ?? ""
            req.logger.error("FCM send failed: status=\(response.status.code) body=\(bodyString)")
            throw Abort(.internalServerError, reason: "Failed to send FCM notification.")
        }

        // Optional: parse response JSON to deactivate invalid tokens here.
    }
}
