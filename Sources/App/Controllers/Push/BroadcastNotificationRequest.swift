//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 14.12.25.
//

import Foundation
import Vapor
import Fluent

struct BroadcastNotificationRequest: Content {
  let title: String
  let body: String

  /// Preferred: send an Expo Router path (e.g. "/(tabs)" or "/news/123")
  let path: String?

  /// Optional convenience: if set, we create path "/news/{newsId}"
  let newsId: String?

  /// Optional: "home" means "/(tabs)"
  let home: Bool?

  let limit: Int?
  let platform: DevicePlatform?
}
