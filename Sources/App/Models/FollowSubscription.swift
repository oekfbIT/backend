//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 14.12.25.
//

import Foundation
import Fluent
import Vapor

enum FollowTargetType: String, Codable {
  case team
  case player
}

final class FollowSubscription: Model, Content {
  static let schema = "follow_subscriptions"

  @ID(key: .id) var id: UUID?
  @Field(key: "guest_id") var guestId: String
  @Field(key: "target_type") var targetType: FollowTargetType
  @Field(key: "target_id") var targetId: UUID
  @Field(key: "is_active") var isActive: Bool

  @Timestamp(key: "created_at", on: .create) var createdAt: Date?
  @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

  init() {}

  init(guestId: String, targetType: FollowTargetType, targetId: UUID, isActive: Bool = true) {
    self.guestId = guestId
    self.targetType = targetType
    self.targetId = targetId
    self.isActive = isActive
  }
}
