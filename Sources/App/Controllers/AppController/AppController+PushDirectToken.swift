//
//  AppController+PushDirectToken.swift
//  oekfbbackend
//
//  Adds: POST /app/notifications/sendToToken
//
//  Assumptions:
//  - ExpoPushService exists (from AppController+Push.swift)
//  - setupPushRoutes(on:) exists and is called from your AppController setup
//

import Vapor
import Fluent
import Foundation

extension AppController {

  // MARK: - DTO

  /// Send to exactly ONE explicit token (token comes from request body).
  /// Useful for debugging, admin tooling, and very targeted messages.
  struct SendToTokenRequest: Content {
    let token: String
    let title: String
    let body: String
    let data: [String: String]?
  }

  // MARK: - Route registration helper

  /// Call this inside `setupPushRoutes(on:)`
  /// e.g. `setupDirectTokenPushRoute(on: route)`
  func setupDirectTokenPushRoute(on route: RoutesBuilder) {
    route.post("notifications", "sendToToken", use: sendToToken)
  }

  // MARK: - Handler

  /// POST /app/notifications/sendToToken
  func sendToToken(req: Request) async throws -> HTTPStatus {
    let dto = try req.content.decode(SendToTokenRequest.self)

    let token = dto.token.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
      throw Abort(.badRequest, reason: "token is empty.")
    }

    try await ExpoPushService.send(
      to: [token],
      title: dto.title,
      body: dto.body,
      data: dto.data ?? [:],
      req: req
    )

    return .ok
  }
}
