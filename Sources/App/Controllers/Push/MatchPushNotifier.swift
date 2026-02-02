```swift
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

  /// One-liner (typical):
  /// `MatchPushNotifier.fire(.goal, match: match, req: req, extra: ["minute":"17", "playerName":"Max Mustermann"])`
  ///
  /// Recommended extra keys you can pass (all optional):
  /// - minute: String
  /// - playerName: String
  /// - playerNumber: String
  /// - teamSide: "home" | "away"
  /// - cardReason: String (optional)
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
          var data = preview.extraData.merging(extra, uniquingKeysWith: { _, new in new })
          data["type"] = preview.type.rawValue
          data["path"] = preview.path
          data["matchId"] = matchId.uuidString
          data["homeTeamId"] = homeId.uuidString
          data["awayTeamId"] = awayId.uuidString
          data["reason"] = preview.reason

          return req.eventLoop.makeFutureWithTask {
            do {
              try await ExpoPushService.send(
                to: tokens,
                title: preview.title,
                body: preview.body,
                data: data,
                req: req
              )
            } catch {
              req.logger.warning("[push] MatchPushNotifier failed: \(error)")
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
    // Adjust to your expo-router route
    let matchIdString = match.id?.uuidString ?? "unknown"
    let path = "/match/\(matchIdString)" // <-- CHANGE if your route differs

    // Dynamic bits
    let scoreText = "\(match.score.home):\(match.score.away)"

    // Common optional extras
    let minute = extra["minute"]
    let playerName = extra["playerName"] ?? extra["name"] // allow both
    let playerNumber = extra["playerNumber"] ?? extra["number"]
    let side = extra["teamSide"] // "home" | "away" (optional)

    func formatPlayerLine() -> String {
      // Examples:
      // "Max Mustermann (10)"
      // "Max Mustermann"
      // "Torschütze unbekannt"
      if let n = playerName, !n.isEmpty {
        if let num = playerNumber, !num.isEmpty {
          return "\(n) (\(num))"
        }
        return n
      }
      return "Torschütze unbekannt"
    }

    func formatMinute() -> String {
      // "17'" or "" if not provided
      if let m = minute, !m.isEmpty {
        return "\(m)′"
      }
      return ""
    }

    func formatTeamPrefix() -> String {
      // Optional hint in title; keep short
      // "HEIM: " / "GAST: "
      switch side?.lowercased() {
      case "home": return "HEIM · "
      case "away": return "GAST · "
      default: return ""
      }
    }

    switch event {
    case .goal:
      // Title: "TOR · 2:1"
      // Body:  "Max Mustermann (10) · 17′"
      return Preview(
        title: "\(formatTeamPrefix())TOR · \(scoreText)",
        body: "\(formatPlayerLine())\(formatMinute().isEmpty ? "" : " · \(formatMinute())")",
        reason: "goal",
        type: .followMatchUpdated,
        path: path,
        extraData: [:]
      )

    case .redCard:
      // Title: "ROTE KARTE · 2:1"
      // Body:  "Max Mustermann (10) · 54′"
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

/*
================================================================================
DOCS / HOW TO USE (MatchController one-liners)
================================================================================

1) Goal
--------
After you updated score + saved match + created MatchEvent (or after save succeeds),
call:

  _ = MatchPushNotifier.fire(.goal, match: match, req: req, extra: [
    "minute": String(goalRequest.minute),
    "playerName": goalRequest.name ?? "",     // or resolve from Player
    "playerNumber": goalRequest.number ?? "", // optional
    "playerId": goalRequest.playerId.uuidString,
    "teamSide": goalRequest.scoreTeam.lowercased() // "home" | "away"
  ])

If you don’t have name/number at that point, pass only minute + playerId and
optionally teamSide; templates will degrade gracefully.

2) Cards (red/yellow/yellowRed)
-------------------------------
In your addCardEvent helper, you already have CardRequest { playerId, minute, name, image, number }
and you can infer teamSide by comparing teamId to match.$homeTeam.id.

  let side = (cardRequest.teamId == match.$homeTeam.id) ? "home" : "away"

  _ = MatchPushNotifier.fire(.yellowCard, match: match, req: req, extra: [
    "minute": String(cardRequest.minute),
    "playerName": cardRequest.name ?? "",
    "playerNumber": cardRequest.number ?? "",
    "playerId": cardRequest.playerId.uuidString,
    "teamSide": side
  ])

3) Game flow
------------
- startGame        -> .gameStarted
- endFirstHalf     -> .halftime
- startSecondHalf  -> .secondHalfStarted
- endGame / done   -> .gameEnded  (pick the one you consider “final”)

Example:

  return match.save(on: req.db).map { _ in
    _ = MatchPushNotifier.fire(.gameStarted, match: match, req: req)
    return .ok
  }

4) Who receives the push?
-------------------------
MatchPushNotifier currently sends to:
- all active follow subscriptions where targetType == .match AND targetId == matchId
- all active follow subscriptions where targetType == .team AND targetId == homeTeamId
- all active follow subscriptions where targetType == .team AND targetId == awayTeamId

Then it resolves DeviceToken rows by guestId and sends to active tokens.

5) Path routing (app)
---------------------
MatchPushNotifier sets:
  data["path"] = "/match/<matchId>"

Your frontend hook (usePushRouting) pushes data.path if present.
Change the path template in buildPreview(...) if your expo-router route differs.

6) Extra payload keys you can use on the client
-----------------------------------------------
We send:
- type: "follow.match.updated"
- path: "/match/<id>"
- matchId, homeTeamId, awayTeamId
- reason: one of the Event reasons ("goal", "yellowCard", ...)

And you can pass-through extra values like:
- minute, playerName, playerNumber, playerId, teamSide

================================================================================
EXAMPLE NOTIFICATION BODIES (by Event)
================================================================================

goal:
  Title: "HEIM · TOR · 2:1"
  Body:  "Max Mustermann (10) · 17′"

redCard:
  Title: "GAST · ROTE KARTE · 2:1"
  Body:  "John Doe (4) · 54′"

yellowCard:
  Title: "HEIM · GELBE KARTE · 0:0"
  Body:  "Max Mustermann (10) · 8′"

yellowRedCard:
  Title: "GAST · GELB-ROT · 1:1"
  Body:  "John Doe (4) · 71′"

gameStarted:
  Title: "ANPFIFF · 0:0"
  Body:  "Das Spiel hat begonnen."

halftime:
  Title: "HALBZEIT · 1:0"
  Body:  "Zwischenstand zur Pause."

secondHalfStarted:
  Title: "2. HALBZEIT · 1:0"
  Body:  "Weiter geht’s!"

gameEnded:
  Title: "ABPFIFF · 2:1"
  Body:  "Endstand."
*/
```
