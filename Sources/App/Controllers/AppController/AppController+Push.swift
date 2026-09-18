//
//  AppController+Push.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 04.12.25.
//

import Vapor
import Fluent
import Foundation

extension AppController {

  // MARK: - Push Types (string contract with frontend)

    enum PushType: String, Content {
      case broadcast = "broadcast"
      case newsOpen = "news.open"
      case conversationMessage = "conversation.message"
      case followTeamUpdated = "follow.team.updated"
      case followPlayerUpdated = "follow.player.updated"
      case followMatchUpdated = "follow.match.updated"
      case postponeRequestCreated = "postpone.request.created"
      case postponeRequestApproved = "postpone.request.approved"
      case postponeRequestDenied = "postpone.request.denied"
    }
  // MARK: - DTOs

  /// Accept multiple token key names from older app builds:
  /// - expoPushToken
  /// - pushToken
  /// - fcmToken (legacy naming in your DB/model)
  ///
  /// NOTE: We still STORE the Expo token in DeviceToken.fcmToken for now.
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

    // Because we implemented init(from:), we must implement Encodable too.
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(guestId, forKey: .guestId)
      try c.encodeIfPresent(playerId, forKey: .playerId)
      try c.encodeIfPresent(teamId, forKey: .teamId)

      // Canonical key
      try c.encode(pushToken, forKey: .pushToken)

      try c.encode(platform, forKey: .platform)
      try c.encodeIfPresent(appVersion, forKey: .appVersion)
      try c.encodeIfPresent(locale, forKey: .locale)
    }
  }

  /// Logout / switch-user helper: clear teamId/playerId for a token, keep token active.
  struct UnbindDeviceRequest: Content {
    let pushToken: String
    let guestId: String?
    let clearTeamId: Bool?
    let clearPlayerId: Bool?
  }

  struct SendNotificationRequest: Content {
    enum TargetType: String, Content {
      case guest
      case player
      case team
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

  /// Broadcast can send:
  /// - home=true     -> "/(tabs)"
  /// - newsId="123"  -> "/news/123" + type "news.open"
  /// - path="/rules" -> type "broadcast"
  struct BroadcastNotificationRequest: Content {
    let title: String
    let body: String

    let path: String?
    let newsId: String?
    let home: Bool?

    let data: [String: String]?

    let limit: Int?
    let platform: DevicePlatform?
  }

  // MARK: - Route registration
  // Call this from AppController.setupRoutes(on:)
  // e.g. `setupPushRoutes(on: route)`

  func setupPushRoutes(on route: RoutesBuilder) {
    // base is already /app because caller passes the grouped route
    route.post("device", "register", use: registerDevice)
    route.post("device", "unbind", use: unbindDevice)

    let admin = route.grouped(AdminOnlyMiddleware())
    admin.post("notifications", "send", use: sendNotification)
    admin.post("notifications", "sendToTokens", use: sendToTokens)
    admin.post("notifications", "broadcast", use: broadcastNotification)
    setupDirectTokenPushRoute(on: admin)
    setupPushManagerRoutes(on: admin)

  }

  // MARK: - Handlers

  /// POST /app/device/register
  /// Upserts by token (stored in DeviceToken.fcmToken).
  func registerDevice(req: Request) async throws -> HTTPStatus {
    let dto = try req.content.decode(RegisterDeviceRequest.self)

    let token = dto.pushToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
      throw Abort(.badRequest, reason: "pushToken is empty.")
    }

    // Treat the app's current identity snapshot as the source of truth. For player
    // logins, derive the team from the player record so a stale/missing team ID
    // in an older app build cannot leave the device detached from its team.
    var resolvedTeamId = dto.teamId
    if let playerId = dto.playerId {
      guard let player = try await Player.find(playerId, on: req.db) else {
        throw Abort(.badRequest, reason: "Unknown playerId.")
      }
      resolvedTeamId = player.$team.id
    }

    if let teamId = resolvedTeamId,
       let team = try await Team.find(teamId, on: req.db) {
      try ApplicationAccess.authorize(team: team, req: req)
    } else if resolvedTeamId != nil {
      throw Abort(.badRequest, reason: "Unknown teamId.")
    }

    let existing = try await DeviceToken.query(on: req.db)
      .filter(\.$fcmToken == token)
      .first()

    if let device = existing {
      device.guestId = dto.guestId
      // A registration is a complete identity snapshot. Assigning nil here is
      // intentional: it clears a previous user when the physical device logs
      // into a different account or returns to guest mode.
      device.playerId = dto.playerId
      device.teamId = resolvedTeamId
      device.platform = dto.platform
      device.appVersion = dto.appVersion ?? device.appVersion
      device.locale = dto.locale ?? device.locale
      device.isActive = true
      try await device.save(on: req.db)
    } else {
      let new = DeviceToken(
        guestId: dto.guestId,
        playerId: dto.playerId,
        teamId: resolvedTeamId,
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

  /// POST /app/device/unbind
  /// Clears teamId/playerId for the given token (logout / switch user).
  func unbindDevice(req: Request) async throws -> HTTPStatus {
    let dto = try req.content.decode(UnbindDeviceRequest.self)

    let token = dto.pushToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty { throw Abort(.badRequest, reason: "pushToken is empty.") }

    guard let device = try await DeviceToken.query(on: req.db)
      .filter(\.$fcmToken == token)
      .first()
    else {
      // idempotent logout: ok even if row doesn't exist
      return .ok
    }

    // Optional safety: ensure the same guest is unbinding this device
    if let gid = dto.guestId, !gid.isEmpty, device.guestId != gid {
      throw Abort(.forbidden, reason: "guestId does not match this device token.")
    }

    if dto.clearTeamId == true { device.teamId = nil }
    if dto.clearPlayerId == true { device.playerId = nil }

    try await device.save(on: req.db)
    return .ok
  }

  /// POST /app/notifications/send
  /// Send to guest/player/team devices (based on stored guestId/playerId/teamId).
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
  /// Debug helper: send directly to explicit token list.
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
  /// Send to ANY active tokens in DB (optionally limit + platform filter).
  func broadcastNotification(req: Request) async throws -> HTTPStatus {
    let body = try req.content.decode(BroadcastNotificationRequest.self)

    var query = DeviceToken.query(on: req.db)
      .filter(\.$isActive == true)

    if let p = body.platform {
      query = query.filter(\.$platform == p)
    }

    let devices = try await query.all()
    var tokens = devices.map(\.fcmToken)

    // trim + de-dupe + remove empties
    tokens = Array(Set(tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
      .filter { !$0.isEmpty }

    if let limit = body.limit, limit > 0, tokens.count > limit {
      tokens = Array(tokens.prefix(limit))
    }

    if tokens.isEmpty {
      throw Abort(.notFound, reason: "No active device tokens found to broadcast to.")
    }

    let resolvedPath: String? = {
      if body.home == true { return "/(tabs)" }
      if let newsId = body.newsId, !newsId.isEmpty { return "/news/\(newsId)" }
      return body.path
    }()

    let type: PushType = (body.newsId != nil) ? .newsOpen : .broadcast

    var data = body.data ?? [:]
    data["type"] = type.rawValue
    if let resolvedPath, !resolvedPath.isEmpty { data["path"] = resolvedPath }
    if let newsId = body.newsId, !newsId.isEmpty { data["newsId"] = newsId }

    try await ExpoPushService.send(
      to: tokens,
      title: body.title,
      body: body.body,
      data: data,
      req: req
    )

    return .ok
  }
}

// MARK: - Expo Push Service

enum ExpoPushService {
  private static let chunkSize = 100
  private static let endpoint = URI(string: "https://exp.host/--/api/v2/push/send")

  struct ExpoMessage: Content {
    let to: String
    let title: String
    let body: String
    let data: [String: String]
    let sound: String
    let priority: String
  }

  struct TicketResult: Content {
    let tokenPreview: String
    let status: String
    let id: String?
    let message: String?
    let error: String?
  }

  struct SendResult: Content {
    let requestedCount: Int
    let acceptedCount: Int
    let failedCount: Int
    let tickets: [TicketResult]
  }

  private struct ExpoResponse: Decodable {
    let data: [ExpoTicket]
  }

  private struct ExpoTicket: Decodable {
    struct Details: Decodable { let error: String? }
    let status: String
    let id: String?
    let message: String?
    let details: Details?
  }

  static func send(
    to tokens: [String],
    title: String,
    body: String,
    data: [String: String],
    req: Request
  ) async throws -> SendResult {
    let logger = req.logger

    let cleaned = Array(Set(tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
      .filter { !$0.isEmpty }

    if cleaned.isEmpty {
      throw Abort(.badRequest, reason: "No push tokens provided.")
    }

    let valid = cleaned.filter(isExpoToken)
    var results = cleaned.filter { !isExpoToken($0) }.map {
      TicketResult(
        tokenPreview: tokenPreview($0),
        status: "error",
        id: nil,
        message: "Invalid Expo push token format.",
        error: "InvalidCredentials"
      )
    }

    for chunk in valid.chunked(into: chunkSize) {
      let payload = chunk.map {
        ExpoMessage(
          to: $0,
          title: title,
          body: body,
          data: data,
          sound: "default",
          priority: "high"
        )
      }

      let res = try await req.client.post(endpoint) { creq in
        creq.headers.replaceOrAdd(name: .contentType, value: "application/json")
        if let accessToken = Environment.get("EXPO_ACCESS_TOKEN"), !accessToken.isEmpty {
          creq.headers.bearerAuthorization = .init(token: accessToken)
        }
        try creq.content.encode(payload, as: .json)
      }

      let raw = bodyString(res.body)

      if res.status != .ok {
        logger.warning("[push] Expo push non-200: \(res.status.code) \(raw)")
        throw Abort(.badGateway, reason: "Expo Push API returned HTTP \(res.status.code).")
      }

      let expoResponse: ExpoResponse
      do {
        expoResponse = try res.content.decode(ExpoResponse.self)
      } catch {
        logger.error("[push] Could not decode Expo response: \(raw)")
        throw Abort(.badGateway, reason: "Expo Push API returned an unreadable response.")
      }
      guard expoResponse.data.count == chunk.count else {
        throw Abort(.badGateway, reason: "Expo Push API returned an unexpected ticket count.")
      }
      for (token, ticket) in zip(chunk, expoResponse.data) {
        results.append(.init(
          tokenPreview: tokenPreview(token),
          status: ticket.status,
          id: ticket.id,
          message: ticket.message,
          error: ticket.details?.error
        ))
      }
    }

    let accepted = results.filter { $0.status == "ok" }.count
    return .init(
      requestedCount: cleaned.count,
      acceptedCount: accepted,
      failedCount: results.count - accepted,
      tickets: results
    )
  }

  private static func isExpoToken(_ token: String) -> Bool {
    (token.hasPrefix("ExpoPushToken[") || token.hasPrefix("ExponentPushToken[")) && token.hasSuffix("]")
  }

  private static func tokenPreview(_ token: String) -> String {
    guard token.count > 12 else { return "••••" }
    return "••••\(token.suffix(8))"
  }

  private static func bodyString(_ body: ByteBuffer?) -> String {
    guard var b = body else { return "" }
    return b.readString(length: b.readableBytes) ?? ""
  }
}

// MARK: - Helpers

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    var res: [[Element]] = []
    res.reserveCapacity((count / size) + 1)

    var i = 0
    while i < count {
      let end = Swift.min(i + size, count)
      res.append(Array(self[i..<end]))
      i = end
    }
    return res
  }
}
