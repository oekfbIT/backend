//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 14.12.25.
//

import Foundation
import Vapor
import Fluent

struct PushDataBuilder {
  static func broadcast(path: String?, reason: String? = nil) -> [String: String] {
    var d: [String: String] = ["type": PushType.broadcast.rawValue]
    if let path, !path.isEmpty { d["path"] = path }
    if let reason { d["reason"] = reason }
    return d
  }

  static func newsOpen(newsId: String) -> [String: String] {
    [
      "type": PushType.newsOpen.rawValue,
      "newsId": newsId,
      "path": "/news/\(newsId)" // optional convenience
    ]
  }

  static func conversation(conversationId: String, teamId: String? = nil) -> [String: String] {
    var d: [String: String] = [
      "type": PushType.conversationMessage.rawValue,
      "conversationId": conversationId
    ]
    if let teamId { d["teamId"] = teamId }
    return d
  }

  static func followTeamUpdated(teamId: String, path: String? = nil, reason: String? = nil) -> [String: String] {
    var d: [String: String] = [
      "type": PushType.followTeamUpdated.rawValue,
      "teamId": teamId
    ]
    if let path { d["path"] = path }
    if let reason { d["reason"] = reason }
    return d
  }

  static func followPlayerUpdated(playerId: String, path: String? = nil, reason: String? = nil) -> [String: String] {
    var d: [String: String] = [
      "type": PushType.followPlayerUpdated.rawValue,
      "playerId": playerId
    ]
    if let path { d["path"] = path }
    if let reason { d["reason"] = reason }
    return d
  }
}

