//
//  AppController+ConversationPush.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 14.12.25.
//

import Vapor
import Fluent
import Foundation

extension AppController {

  /// Call this after you saved the message, when the sender is ADMIN (senderTeam == false).
  ///
  /// Sends push to all active device tokens that are currently bound to that teamId.
  func pushNewConversationMessageToTeamDevices(
    req: Request,
    teamId: UUID,
    conversationId: UUID,
    bodyText: String
  ) -> EventLoopFuture<Void> {
    return req.eventLoop.makeFutureWithTask {
      let tokens = try await DeviceToken.query(on: req.db)
        .filter(\.$teamId == teamId)
        .filter(\.$isActive == true)
        .all()
        .map(\.fcmToken)

      if tokens.isEmpty { return }

      let finalBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Sie haben eine neue Nachricht."
        : bodyText

      try await ExpoPushService.send(
        to: tokens,
        title: "Neue Nachricht",
        body: finalBody,
        data: [
          "type": PushType.conversationMessage.rawValue,
          "conversationId": conversationId.uuidString,
          "teamId": teamId.uuidString,
        ],
        req: req
      )
    }
  }
}
