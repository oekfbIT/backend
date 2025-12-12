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

  /// Accept multiple token key names from app builds:
  /// - expoPushToken
  /// - pushToken
  /// - fcmToken (legacy column name in DB)
  ///
  /// NOTE: We still STORE the token in DeviceToken.fcmToken for now.
  struct RegisterDeviceRequest: Content {
    let guestId: String
    let playerId: UUID?
    let teamId: UUID?
    let pushToken: String
    let platform: DevicePlatform
    let appVersion: String?
    let locale: String?

    enum CodingKeys: String, CodingKey {
      case guestId
      case playerId
      case teamId
      case expoPushToken
      case pushToken
      case fcmToken
      case platform
      case appVersion
      case locale
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)

      guestId = try c.decode(String.self, forKey: .guestId)
      playerId = try c.decodeIfPresent(UUID.self, forKey: .playerId)
      teamId = try c.decodeIfPresent(UUID.self, forKey: .teamId)

      if let v = try c.decodeIfPresent(String.self, forKey: .expoPushToken) {
        pushToken = v
      } else if let v = try c.decodeIfPresent(String.self, forKey: .pushToken) {
        pushToken = v
      } else if let v = try c.decodeIfPresent(String.self, forKey: .fcmToken) {
        pushToken = v
      } else {
        throw Abort(.badRequest, reason: "Missing push token (expoPushToken / pushToken / fcmToken).")
      }

      platform = try c.decode(DevicePlatform.self, forKey: .platform)
      appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
      locale = try c.decodeIfPresent(String.self, forKey: .locale)
    }

    // ✅ Fix: because we implemented init(from:), Swift doesn't auto-synthesize Encodable.
    // Vapor's Content = Codable, so we must implement encode(to:) too.
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(guestId, forKey: .guestId)
      try c.encodeIfPresent(playerId, forKey: .playerId)
      try c.encodeIfPresent(teamId, forKey: .teamId)

      // Write the canonical key (pushToken). (We could also write expoPushToken if you want.)
      try c.encode(pushToken, forKey: .pushToken)

      try c.encode(platform, forKey: .platform)
      try c.encodeIfPresent(appVersion, forKey: .appVersion)
      try c.encodeIfPresent(locale, forKey: .locale)
    }
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

  struct SendToTokensRequest: Content {
    let tokens: [String]
    let title: String
    let body: String
    let data: [String: String]?
  }

  struct BroadcastNotificationRequest: Content {
    let title: String
    let body: String
    let data: [String: String]?

    /// Safety valve during testing
    let limit: Int?

    /// Optional: only broadcast to one platform while debugging
    let platform: DevicePlatform?
  }

  // MARK: - Routes

  /// POST /app/device/register
  ///
  /// Upserts a DeviceToken by token (stored in fcmToken column).
  func registerDevice(req: Request) async throws -> HTTPStatus {
    let dto = try req.content.decode(RegisterDeviceRequest.self)

    let token = dto.pushToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
      throw Abort(.badRequest, reason: "pushToken is empty.")
    }

    let existing = try await DeviceToken.query(on: req.db)
      .filter(\.$fcmToken == token)
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
        fcmToken: token,
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
  /// Send push to devices selected by guest/player/team.
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

    try await ExpoPushService.send(
      to: tokens,
      title: body.title,
      body: body.body,
      data: body.data ?? [:],
      req: req
    )

    return .ok
  }

  /// POST /app/notifications/sendToTokens
  ///
  /// Directly send to a list of Expo push tokens (for debugging).
  func sendToTokens(req: Request) async throws -> HTTPStatus {
    let body = try req.content.decode(SendToTokensRequest.self)

    try await ExpoPushService.send(
      to: body.tokens,
      title: body.title,
      body: body.body,
      data: body.data ?? [:],
      req: req
    )

    return .ok
  }

  /// POST /app/notifications/broadcast
  ///
  /// TEST endpoint: send to ANY active tokens in DB (optionally limit + platform filter).
  func broadcastNotification(req: Request) async throws -> HTTPStatus {
    let body = try req.content.decode(BroadcastNotificationRequest.self)

    var query = DeviceToken.query(on: req.db)
      .filter(\.$isActive == true)

    if let p = body.platform {
      query = query.filter(\.$platform == p)
    }

    let devices = try await query.all()
    var tokens = devices.map(\.fcmToken)

    // safety: trim + de-dupe + remove empties
    tokens = Array(Set(tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
      .filter { !$0.isEmpty }

    if let limit = body.limit, limit > 0, tokens.count > limit {
      tokens = Array(tokens.prefix(limit))
    }

    if tokens.isEmpty {
      throw Abort(.notFound, reason: "No active device tokens found to broadcast to.")
    }

    try await ExpoPushService.send(
      to: tokens,
      title: body.title,
      body: body.body,
      data: body.data ?? [:],
      req: req
    )

    return .ok
  }
}
