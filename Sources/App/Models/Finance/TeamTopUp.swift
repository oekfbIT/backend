import Crypto
import Foundation
import Vapor

struct TeamTopUpInput: Content {
    let amountMinor: Int
    let idempotencyKey: String

    func validate(maximum: Int) throws {
        guard (50...maximum).contains(amountMinor) else {
            throw Abort(.badRequest, reason: "amount_minor must be between 50 and \(maximum) EUR cents.")
        }
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 128,
              idempotencyKey.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Use a UUID or 1–128 letters, digits, underscores or hyphens for idempotency_key.")
        }
    }
}

enum TeamTopUpPaymentFlow: String, Codable {
    case sdk, checkout
}

/// Internal Mongo document. Never return this record (it includes a client secret and email).
struct TeamTopUp: Codable {
    static let schema = "team_stripe_topups"
    let id: String
    let teamID: UUID
    let userID: UUID
    let teamName: String
    let recipient: String
    let amountMinor: Int
    let livemode: Bool
    let createdAt: Date
    var paymentIntentID: String?
    var clientSecret: String?
    var stripeStatus: String
    var chargeID: String?
    var paidAt: Date?
    var creditedAt: Date?
    var balanceBefore: Double?
    var balanceAfter: Double?
    var emailSentAt: Date?
    var lastError: String?
    var needsReview: Bool
    var nextAttemptAt: Date
    var leaseUntil: Date
    // Optional so previously stored SDK top-ups remain readable.
    var paymentFlow: TeamTopUpPaymentFlow?
    var checkoutSessionID: String?
    var checkoutURL: String?
    var checkoutStatus: String?
    var checkoutExpiresAt: Date?
    var checkoutSuccessURL: String?
    var checkoutCancelURL: String?
    var paymentFailed: Bool?

    var flow: TeamTopUpPaymentFlow { paymentFlow ?? .sdk }
    var status: String {
        if creditedAt != nil { return "credited" }
        if needsReview { return "needs_review" }
        if stripeStatus == "succeeded" { return "succeeded" }
        if checkoutStatus == "expired" { return "expired" }
        if paymentFailed == true && stripeStatus == "requires_payment_method" { return "payment_failed" }
        return stripeStatus
    }

    var confirmationHTTPStatus: HTTPStatus {
        switch status {
        case "credited": return .ok
        case "needs_review": return .conflict
        case "expired", "canceled": return .gone
        case "payment_failed": return .paymentRequired
        default: return .accepted
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case teamID, userID, teamName, recipient, amountMinor, livemode, createdAt
        case paymentIntentID, clientSecret, stripeStatus, chargeID, paidAt, creditedAt
        case balanceBefore, balanceAfter, emailSentAt, lastError, needsReview, nextAttemptAt, leaseUntil
        case paymentFlow, checkoutSessionID, checkoutURL, checkoutStatus, checkoutExpiresAt
        case checkoutSuccessURL, checkoutCancelURL, paymentFailed
    }

    init(teamID: UUID, userID: UUID, teamName: String, recipient: String, input: TeamTopUpInput, livemode: Bool, now: Date = Date()) {
        id = Self.identifier(teamID: teamID, userID: userID, key: input.idempotencyKey, livemode: livemode)
        self.teamID = teamID; self.userID = userID; self.teamName = teamName
        self.recipient = recipient; amountMinor = input.amountMinor; self.livemode = livemode
        createdAt = now; stripeStatus = "creating"; needsReview = false
        nextAttemptAt = now; leaseUntil = .distantPast
    }

    static func identifier(teamID: UUID, userID: UUID, key: String, livemode: Bool) -> String {
        let value = "oekfb-topup:\(livemode):\(teamID.uuidString):\(userID.uuidString):\(key)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var invoiceID: UUID {
        // One immutable invoice ID per deposit, including after recovery/replayed webhooks.
        let hex = Array(id.prefix(32))
        let string = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
                      String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        return UUID(uuidString: string)!
    }

    var invoiceNumber: String { "STRIPE-\(id.prefix(20).uppercased())" }
}

struct TeamTopUpResponse: Content {
    let id: String
    let teamId: UUID
    let amountMinor: Int
    let currency: String
    let status: String
    let stripeStatus: String
    let paymentIntentId: String?
    let clientSecret: String?
    let publishableKey: String
    let invoiceId: UUID?
    let balanceBefore: Double?
    let balanceAfter: Double?
    let paidAt: Date?
    let creditedAt: Date?
    let emailSentAt: Date?
    let paymentFlow: TeamTopUpPaymentFlow
    let checkoutSessionId: String?
    let checkoutUrl: String?
    let checkoutStatus: String?
    let checkoutExpiresAt: Date?

    init(_ topUp: TeamTopUp, publishableKey: String, includeSecret: Bool = true) {
        id = topUp.id; teamId = topUp.teamID; amountMinor = topUp.amountMinor; currency = "eur"
        status = topUp.status
        stripeStatus = topUp.stripeStatus; paymentIntentId = topUp.paymentIntentID
        clientSecret = includeSecret && topUp.flow == .sdk && topUp.creditedAt == nil ? topUp.clientSecret : nil
        self.publishableKey = publishableKey
        invoiceId = topUp.creditedAt == nil ? nil : topUp.invoiceID
        balanceBefore = topUp.balanceBefore; balanceAfter = topUp.balanceAfter
        paidAt = topUp.paidAt; creditedAt = topUp.creditedAt; emailSentAt = topUp.emailSentAt
        paymentFlow = topUp.flow; checkoutSessionId = topUp.checkoutSessionID
        checkoutStatus = topUp.checkoutStatus; checkoutExpiresAt = topUp.checkoutExpiresAt
        checkoutUrl = topUp.creditedAt == nil && topUp.checkoutStatus == "open" ? topUp.checkoutURL : nil
    }
}

struct StripeDepositDetails: Content {
    let topUpId: String
    let paymentIntentId: String
    let chargeId: String?
    let amountMinor: Int
    let currency: String
    let paidAt: Date
    let balanceAfter: Double
    let livemode: Bool
}
