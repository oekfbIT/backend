//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 12.12.25.
//

import Foundation
import Vapor

/// Central place to send push notifications (Expo Push Service).
final class NotificationManager {
    private let client: Client
    private let logger: Logger

    init(client: Client, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    struct ExpoPushMessage: Content {
        let to: String
        let title: String
        let body: String
        let sound: String?
        let data: [String: String]?
        let priority: String?

        init(
            to: String,
            title: String,
            body: String,
            data: [String: String]? = nil,
            sound: String? = nil,
            priority: String? = "high"
        ) {
            self.to = to
            self.title = title
            self.body = body
            self.data = data
            self.sound = sound
            self.priority = priority
        }
    }

    struct ExpoPushResponse: Content {
        struct Ticket: Content {
            let status: String?
            let id: String?
            let message: String?
            let details: [String: String]?
        }
        let data: [Ticket]?
        let errors: [String]?
    }

    /// Expo tokens look like "ExponentPushToken[xxxx]" or "ExpoPushToken[xxxx]"
    func isValidExpoToken(_ token: String) -> Bool {
        token.hasPrefix("ExponentPushToken[") || token.hasPrefix("ExpoPushToken[")
    }

    /// Send to many expo tokens. Expo allows arrays; keep chunks small (100 is safe).
    func sendExpoPush(
        to tokens: [String],
        title: String,
        body: String,
        data: [String: String]? = nil
    ) async throws {
        let valid = tokens.filter(isValidExpoToken)
        guard !valid.isEmpty else {
            logger.info("[push] No valid Expo tokens to send")
            return
        }

        let url = URI(string: "https://exp.host/--/api/v2/push/send")

        // Chunk tokens
        let chunks = stride(from: 0, to: valid.count, by: 100).map {
            Array(valid[$0..<min($0 + 100, valid.count)])
        }

        for (idx, chunk) in chunks.enumerated() {
            let payload = chunk.map {
                ExpoPushMessage(to: $0, title: title, body: body, data: data, sound: nil, priority: "high")
            }

            logger.info("[push] Sending Expo push chunk \(idx+1)/\(chunks.count) size=\(payload.count)")

            let res = try await client.post(url) { req in
                req.headers.contentType = .json
                try req.content.encode(payload)
            }

//            if res.status != .ok {
//                let raw = res.body?.string ?? ""
//                logger.warning("[push] Expo push non-200: \(res.status.code) \(raw)")
//                continue
//            }
//
//            // Optional: decode tickets for debugging
//            if let bodyData = res.body?.string, !bodyData.isEmpty {
//                logger.debug("[push] Expo push response: \(bodyData)")
//            }
        }
    }
}

// MARK: - App storage hook
extension Application {
    private struct NotificationManagerKey: StorageKey {
        typealias Value = NotificationManager
    }

    var notificationManager: NotificationManager {
        get {
            guard let mgr = self.storage[NotificationManagerKey.self] else {
                fatalError("NotificationManager not set.")
            }
            return mgr
        }
        set { self.storage[NotificationManagerKey.self] = newValue }
    }
}
