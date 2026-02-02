//
//  CreateFollowSubscription.swift
//  oekfbbackend
//

import Fluent

struct CreateFollowSubscription: AsyncMigration {
  func prepare(on database: Database) async throws {
    try await database.schema(FollowSubscription.schema)
      .id()
      .field("guest_id", .string, .required)
      .field("target_type", .string, .required) // "team" | "player"
      .field("target_id", .uuid, .required)
      .field("is_active", .bool, .required)
      .field("created_at", .datetime)
      .field("updated_at", .datetime)
      // Prevent duplicates per guest/target
      .unique(on: "guest_id", "target_type", "target_id")
      .create()
  }

  func revert(on database: Database) async throws {
    try await database.schema(FollowSubscription.schema).delete()
  }
}
