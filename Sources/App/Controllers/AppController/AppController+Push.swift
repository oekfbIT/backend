//
//  AppController+Push.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 04.12.25.
//

import Vapor
import Fluent

extension AppController {
    // MARK: - DTOs

    struct RegisterDeviceRequest: Content {
        let guestId: String
        let playerId: UUID?
        let teamId: UUID?
        let fcmToken: String
        let platform: DevicePlatform
        let appVersion: String?
        let locale: String?
    }

    struct SendNotificationRequest: Content {
        enum TargetType: String, Content {
            case guest   // targetId = guestId (String)
            case player  // targetId = player UUID string
            case team    // targetId = team UUID string
        }

        let target: TargetType
        let targetId: String
        let title: String
        let body: String
        let data: [String: String]?
    }

    // MARK: - Routes

    /// POST /app/device/register
    ///
    /// Called by the app whenever:
    /// - guest installs / opens app
    /// - user logs in as player
    /// - user logs in as team
    ///
    /// Upserts a DeviceToken by fcmToken.
    func registerDevice(req: Request) async throws -> HTTPStatus {
        let dto = try req.content.decode(RegisterDeviceRequest.self)

        // Upsert by fcmToken
        let existing = try await DeviceToken.query(on: req.db)
            .filter(\.$fcmToken == dto.fcmToken)
            .first()

        if let device = existing {
            device.guestId = dto.guestId
            device.playerId = dto.playerId ?? device.playerId
            device.teamId = dto.teamId ?? device.teamId
            device.platform = dto.platform
            device.appVersion = dto.appVersion ?? device.appVersion
            device.locale = dto.locale ?? device.locale
            device.isActive = true
            try await device.save(on: req.db)
        } else {
            let new = DeviceToken(
                guestId: dto.guestId,
                playerId: dto.playerId,
                teamId: dto.teamId,
                fcmToken: dto.fcmToken,
                platform: dto.platform,
                appVersion: dto.appVersion,
                locale: dto.locale,
                isActive: true
            )
            try await new.save(on: req.db)
        }

        return .ok
    }

    /// POST /app/notifications/send
    ///
    /// Admin / backend endpoint:
    /// Send a push to:
    /// - all devices with given guestId
    /// - all devices with given playerId
    /// - all devices with given teamId
    func sendNotification(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(SendNotificationRequest.self)

        let tokens: [String]

        switch body.target {
        case .guest:
            tokens = try await DeviceToken.query(on: req.db)
                .filter(\.$guestId == body.targetId)
                .filter(\.$isActive == true)
                .all()
                .map(\.fcmToken)

        case .player:
            guard let uuid = UUID(uuidString: body.targetId) else {
                throw Abort(.badRequest, reason: "Invalid player UUID in targetId.")
            }
            tokens = try await DeviceToken.query(on: req.db)
                .filter(\.$playerId == uuid)
                .filter(\.$isActive == true)
                .all()
                .map(\.fcmToken)

        case .team:
            guard let uuid = UUID(uuidString: body.targetId) else {
                throw Abort(.badRequest, reason: "Invalid team UUID in targetId.")
            }
            tokens = try await DeviceToken.query(on: req.db)
                .filter(\.$teamId == uuid)
                .filter(\.$isActive == true)
                .all()
                .map(\.fcmToken)
        }

        try await FCMService.send(
            to: tokens,
            title: body.title,
            body: body.body,
            data: body.data ?? [:],
            req: req
        )

        return .ok
    }
}
