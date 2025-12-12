import Foundation
import Vapor
import Fluent

// MARK: - Expo Push Service

enum ExpoPushService {
  /// Expo docs: up to 100 messages per request
  private static let chunkSize = 100
  private static let endpoint = URI(string: "https://exp.host/--/api/v2/push/send")

  struct ExpoMessage: Content {
    let to: String
    let title: String
    let body: String
    let data: [String: String]
    // You can add `sound`, `badge`, `priority`, etc. later if you want.
  }

  static func send(
    to tokens: [String],
    title: String,
    body: String,
    data: [String: String],
    req: Request
  ) async throws {
    let logger = req.logger

    let cleaned = Array(Set(tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
      .filter { !$0.isEmpty }

    if cleaned.isEmpty {
      logger.warning("[push] No tokens provided.")
      return
    }

    for chunk in cleaned.chunked(into: chunkSize) {
      let payload = chunk.map { ExpoMessage(to: $0, title: title, body: body, data: data) }

      let res = try await req.client.post(endpoint) { creq in
        creq.headers.replaceOrAdd(name: .contentType, value: "application/json")
        try creq.content.encode(payload, as: .json)
      }

      // ✅ Fix for your error: don't use res.body?.string (fileprivate). Read ByteBuffer safely.
      let raw = bodyString(res.body)

      if res.status != .ok {
        logger.warning("[push] Expo push non-200: \(res.status.code) \(raw)")
        continue
      }

      if !raw.isEmpty {
        logger.debug("[push] Expo push response: \(raw)")
      }
    }
  }

  private static func bodyString(_ body: ByteBuffer?) -> String {
    guard var b = body else { return "" }
    return b.readString(length: b.readableBytes) ?? ""
  }
}

// MARK: - Small helpers

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    var res: [[Element]] = []
    res.reserveCapacity((count / size) + 1)

    var i = 0
    while i < count {
      let end = Swift.min(i + size, count)
      res.append(Array(self[i..<end]))
      i = end
    }
    return res
  }
}
