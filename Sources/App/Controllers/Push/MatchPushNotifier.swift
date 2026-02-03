import Vapor
import Fluent
import Foundation

/// One place to define *what* is sent and *who* receives it.
/// Call it from MatchController as a one-liner.
enum MatchPushNotifier {

  // MARK: - Event catalog (single enum)

  enum Event: String, CaseIterable {
    // match events
    case goal
    case redCard
    case yellowCard
    case yellowRedCard

    // game flow
    case gameStarted
    case halftime
    case secondHalfStarted
    case gameEnded
  }

  // MARK: - Preview templates

  struct Preview {
    let title: String
    let body: String
    let reason: String
    let type: AppController.PushType
    let path: String
    let extraData: [String: String]

    /// Convenient for logging / UI previews
    var debugLine: String { "[\(reason)] \(title) — \(body) → \(path)" }
  }

  // MARK: - Public API (one-liner friendly)

  static func fire(
    _ event: Event,
    match: Match,
    req: Request,
    extra: [String: String] = [:]
  ) -> EventLoopFuture<Void> {

    guard let matchId = match.id else {
      return req.eventLoop.makeSucceededFuture(())
    }

    let homeId = match.$homeTeam.id
    let awayId = match.$awayTeam.id

    // 1) Build preview from template
    let preview = buildPreview(event, match: match, extra: extra)

    // 2) Resolve recipients: match followers + home team followers + away team followers
    return resolveFollowerGuestIds(
      matchId: matchId,
      homeTeamId: homeId,
      awayTeamId: awayId,
      on: req.db
    )
    .flatMap { guestIds in
      if guestIds.isEmpty {
        return req.eventLoop.makeSucceededFuture(())
      }

      // 3) Resolve device tokens for those guestIds
      return resolveActiveTokens(guestIds: guestIds, on: req.db)
        .flatMap { tokens in
          if tokens.isEmpty {
            return req.eventLoop.makeSucceededFuture(())
          }

          // 4) Send push (ExpoPushService is async)
          // ✅ Build immutable payload BEFORE crossing into async task
          let payload: [String: String] = {
            var dict = preview.extraData.merging(extra, uniquingKeysWith: { _, new in new })
            dict["type"] = preview.type.rawValue
            dict["path"] = preview.path
            dict["matchId"] = matchId.uuidString
            dict["homeTeamId"] = homeId.uuidString
            dict["awayTeamId"] = awayId.uuidString
            dict["reason"] = preview.reason
            return dict
          }()

          let logger = req.logger

          return req.eventLoop.makeFutureWithTask {
            do {
              try await ExpoPushService.send(
                to: tokens,
                title: preview.title,
                body: preview.body,
                data: payload,
                req: req
              )
            } catch {
              logger.warning("[push] MatchPushNotifier failed: \(error)")
            }
          }
        }
    }
  }

  /// For admin screens / debugging: show what the push would look like.
  static func preview(
    _ event: Event,
    match: Match,
    extra: [String: String] = [:]
  ) -> Preview {
    buildPreview(event, match: match, extra: extra)
  }

  // MARK: - Templates

  private static func buildPreview(_ event: Event, match: Match, extra: [String: String]) -> Preview {
    let matchIdString = match.id?.uuidString ?? "unknown"
    let path = "/match/\(matchIdString)"

    let scoreText = "\(match.score.home):\(match.score.away)"

    let minute = extra["minute"]
    let playerName = extra["playerName"] ?? extra["name"]
    let playerNumber = extra["playerNumber"] ?? extra["number"]
    let side = extra["teamSide"]

    func formatPlayerLine() -> String {
      if let n = playerName, !n.isEmpty {
        if let num = playerNumber, !num.isEmpty { return "\(n) (\(num))" }
        return n
      }
      return "Torschütze unbekannt"
    }

    func formatMinute() -> String {
      if let m = minute, !m.isEmpty { return "\(m)′" }
      return ""
    }

    func formatTeamPrefix() -> String {
      switch side?.lowercased() {
      case "home": return "HEIM · "
      case "away": return "GAST · "
      default: return ""
      }
    }

    switch event {
    case .goal:
      return Preview(
        title: "\(formatTeamPrefix())TOR · \(scoreText)",
        body: "\(formatPlayerLine())\(formatMinute().isEmpty ? "" : " · \(formatMinute())")",
        reason: "goal",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .redCard:
      return Preview(
        title: "\(formatTeamPrefix())ROTE KARTE · \(scoreText)",
        body: "\(playerName?.isEmpty == false ? formatPlayerLine() : "Spieler unbekannt")\(formatMinute().isEmpty ? "" : " · \(formatMinute())")",
        reason: "redCard",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .yellowCard:
      return Preview(
        title: "\(formatTeamPrefix())GELBE KARTE · \(scoreText)",
        body: "\(playerName?.isEmpty == false ? formatPlayerLine() : "Spieler unbekannt")\(formatMinute().isEmpty ? "" : " · \(formatMinute())")",
        reason: "yellowCard",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .yellowRedCard:
      return Preview(
        title: "\(formatTeamPrefix())GELB-ROT · \(scoreText)",
        body: "\(playerName?.isEmpty == false ? formatPlayerLine() : "Spieler unbekannt")\(formatMinute().isEmpty ? "" : " · \(formatMinute())")",
        reason: "yellowRedCard",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .gameStarted:
      return Preview(
        title: "ANPFIFF · \(scoreText)",
        body: "Das Spiel hat begonnen.",
        reason: "gameStarted",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .halftime:
      return Preview(
        title: "HALBZEIT · \(scoreText)",
        body: "Zwischenstand zur Pause.",
        reason: "halftime",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .secondHalfStarted:
      return Preview(
        title: "2. HALBZEIT · \(scoreText)",
        body: "Weiter geht’s!",
        reason: "secondHalfStarted",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .gameEnded:
      return Preview(
        title: "ABPFIFF · \(scoreText)",
        body: "Endstand.",
        reason: "gameEnded",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )
    }
  }

  // MARK: - Recipient resolution

  private static func resolveFollowerGuestIds(
    matchId: UUID,
    homeTeamId: UUID,
    awayTeamId: UUID,
    on db: Database
  ) -> EventLoopFuture<[String]> {

    FollowSubscription.query(on: db)
      .filter(\.$isActive == true)
      .group(.or) { or in
        or.group(.and) { and in
          and.filter(\.$targetType == .match)
          and.filter(\.$targetId == matchId)
        }
        or.group(.and) { and in
          and.filter(\.$targetType == .team)
          and.filter(\.$targetId == homeTeamId)
        }
        or.group(.and) { and in
          and.filter(\.$targetType == .team)
          and.filter(\.$targetId == awayTeamId)
        }
      }
      .all()
      .map { subs in
        Array(Set(subs.map(\.guestId))).filter { !$0.isEmpty }
      }
  }

  private static func resolveActiveTokens(
    guestIds: [String],
    on db: Database
  ) -> EventLoopFuture<[String]> {

    DeviceToken.query(on: db)
      .filter(\.$isActive == true)
      .filter(\.$guestId ~~ guestIds)
      .all()
      .map { devices in
        Array(Set(devices.map(\.fcmToken)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
          .filter { !$0.isEmpty }
      }
  }
}
