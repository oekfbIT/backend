//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 14.12.25.
//

import Foundation
import Vapor
import Fluent

enum PushType: String, Content {
  case broadcast = "broadcast"
  case newsOpen = "news.open"
  case conversationMessage = "conversation.message"
  case followTeamUpdated = "follow.team.updated"
  case followPlayerUpdated = "follow.player.updated"
}
