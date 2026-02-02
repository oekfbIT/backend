//
//  AppController+Follow.swift
//  oekfbbackend
//
//  Follow API for:
//  - Following a team or a player
//  - Listing follows by guestId
//  - Deleting a follow subscription
//
//  Binding choice (for now):
//  - guestId (per-install, anonymous-friendly)
//  - later we can add userId binding if you want
//
//  Routes (base /app):
//    POST   /app/follow                 -> upsert follow
//    GET    /app/follow/guest/:guestId  -> list follows for a guest
//    DELETE /app/follow/:id             -> delete follow by id
//

import Vapor
import Fluent
import Foundation

extension AppController {

  // MARK: - DTOs

  struct UpsertFollowRequest: Content {
    let guestId: String
    let targetType: FollowTargetType // team | player
    let targetId: UUID
    let isActive: Bool?
  }

  struct FollowListResponse: Content {
    let items: [FollowSubscription]
  }

  // MARK: - Route registration

  func setupFollowRoutes(on route: RoutesBuilder) {
    let follow = route.grouped("follow")

    follow.post(use: upsertFollow)
    follow.get("guest", ":guestId", use: listFollowsForGuest)
    follow.delete(":id", use: deleteFollow)
  }

  // MARK: - Handlers

  /// POST /app/follow
  ///
  /// Idempotent upsert keyed by (guestId, targetType, targetId)
  /// - If exists: update isActive
  /// - Else: create
  func upsertFollow(req: Request) async throws -> FollowSubscription {
    let dto = try req.content.decode(UpsertFollowRequest.self)

    let guestId = dto.guestId.trimmingCharacters(in: .whitespacesAndNewlines)
    if guestId.isEmpty {
      throw Abort(.badRequest, reason: "guestId is empty.")
    }

    // Guard: only allow team/player (already enforced by enum, but keep explicit)
    switch dto.targetType {
    case .team, .player:
      break
    }

    if let existing = try await FollowSubscription.query(on: req.db)
      .filter(\.$guestId == guestId)
      .filter(\.$targetType == dto.targetType)
      .filter(\.$targetId == dto.targetId)
      .first()
    {
      existing.isActive = dto.isActive ?? true
      try await existing.save(on: req.db)
      return existing
    }

    let created = FollowSubscription(
      guestId: guestId,
      targetType: dto.targetType,
      targetId: dto.targetId,
      isActive: dto.isActive ?? true
    )
    try await created.save(on: req.db)
    return created
  }

  /// GET /app/follow/guest/:guestId
  func listFollowsForGuest(req: Request) async throws -> FollowListResponse {
    guard let guestIdRaw = req.parameters.get("guestId") else {
      throw Abort(.badRequest, reason: "Missing guestId param.")
    }

    let guestId = guestIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    if guestId.isEmpty {
      throw Abort(.badRequest, reason: "guestId is empty.")
    }

    let items = try await FollowSubscription.query(on: req.db)
      .filter(\.$guestId == guestId)
      .sort(\.$updatedAt, .descending)
      .all()

    return FollowListResponse(items: items)
  }

  /// DELETE /app/follow/:id
  func deleteFollow(req: Request) async throws -> HTTPStatus {
    guard let id = req.parameters.get("id", as: UUID.self) else {
      throw Abort(.badRequest, reason: "Invalid follow subscription id.")
    }

    // idempotent delete
    guard let row = try await FollowSubscription.find(id, on: req.db) else {
      return .noContent
    }

    try await row.delete(on: req.db)
    return .noContent
  }
}
