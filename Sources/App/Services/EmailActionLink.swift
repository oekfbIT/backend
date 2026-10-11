import Crypto
import Foundation
import Vapor

/// A mail link grants access to one request, never to the underlying model routes.
enum EmailActionLink {
    static func token(kind: String, id: UUID) throws -> String {
        guard let secret = Environment.get("EMAIL_ACTION_SECRET"), secret.utf8.count >= 32 else {
            throw Abort(.serviceUnavailable, reason: "Email action links are not configured.")
        }
        let message = Data("oekfb-email-action-v1:\(kind):\(id.uuidString.lowercased())".utf8)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    static func require(_ req: Request, kind: String, id: UUID) throws {
        guard let supplied = req.headers.first(name: "X-Email-Action-Token"),
              let suppliedBytes = Data(hex: supplied),
              suppliedBytes.count == 32,
              let expected = Data(hex: try token(kind: kind, id: id)),
              constantTimeEqual(suppliedBytes, expected) else {
            throw Abort(.unauthorized, reason: "Dieser Bestätigungslink ist ungültig.")
        }
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
