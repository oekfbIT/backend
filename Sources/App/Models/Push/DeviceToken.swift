//
//  DeviceToken.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 04.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - Platform enum

enum DevicePlatform: String, Codable, CaseIterable {
    case ios
    case android
}

// MARK: - Model

final class DeviceToken: Model, Content {
    static let schema = "device_tokens"

    @ID(key: .id)
    var id: UUID?

    /// Guest identifier from the app (stored per-install).
    @Field(key: "guest_id")
    var guestId: String

    /// Optional logged-in player ID (your Player UUID).
    @OptionalField(key: "player_id")
    var playerId: UUID?

    /// Optional logged-in team ID (your Team UUID).
    @OptionalField(key: "team_id")
    var teamId: UUID?

    /// FCM registration token for this device.
    @Field(key: "fcm_token")
    var fcmToken: String

    /// iOS / Android
    @Enum(key: "platform")
    var platform: DevicePlatform

    /// Optional app version (e.g. "1.0.3")
    @OptionalField(key: "app_version")
    var appVersion: String?

    /// Optional locale (e.g. "de-AT")
    @OptionalField(key: "locale")
    var locale: String?

    /// Soft-delete / deactivation flag when FCM says token is invalid.
    @Field(key: "is_active")
    var isActive: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        guestId: String,
        playerId: UUID? = nil,
        teamId: UUID? = nil,
        fcmToken: String,
        platform: DevicePlatform,
        appVersion: String? = nil,
        locale: String? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.guestId = guestId
        self.playerId = playerId
        self.teamId = teamId
        self.fcmToken = fcmToken
        self.platform = platform
        self.appVersion = appVersion
        self.locale = locale
        self.isActive = isActive
    }
}

// MARK: - Migration

extension CreateDeviceToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(DeviceToken.schema)
            .id()
            .field("guest_id", .string, .required)
            .field("player_id", .uuid)
            .field("team_id", .uuid)
            .field("fcm_token", .string, .required)
            .field("platform", .string, .required)
            .field("app_version", .string)
            .field("locale", .string)
            .field("is_active", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "fcm_token")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(DeviceToken.schema).delete()
    }
}
