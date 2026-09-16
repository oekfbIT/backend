import Crypto
import Foundation
import Vapor

struct TeamStripeConfiguration {
    let mode: String
    let secretKey: String
    let publishableKey: String
    let webhookSecret: String
    let maximumMinor: Int
    let checkoutSuccessURL: String?
    let checkoutCancelURL: String?
    var livemode: Bool { secretKey.hasPrefix("sk_live_") }

    init(environment: (String) -> String? = Environment.get) throws {
        mode = environment("STRIPE_MODE") ?? "sandbox"
        guard ["sandbox", "production"].contains(mode) else {
            throw Abort(.serviceUnavailable, reason: "STRIPE_MODE must be sandbox or production.")
        }
        let prefix = mode == "production" ? "STRIPE_PRODUCTION" : "STRIPE_SANDBOX"
        secretKey = environment("\(prefix)_SECRET_KEY") ?? ""
        publishableKey = environment("\(prefix)_PUBLISHABLE_KEY") ?? ""
        webhookSecret = environment("\(prefix)_WEBHOOK_SECRET") ?? ""
        maximumMinor = Int(environment("STRIPE_TOPUP_MAX_MINOR") ?? "500000") ?? 0
        // A built-in neutral return page makes hosted Checkout usable without a separate website.
        func configuredReturn(_ key: String) -> String? {
            guard let value = environment(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let returnBase = configuredReturn("STRIPE_CHECKOUT_BASE_URL") ?? "https://api.oekfb.eu"
        checkoutSuccessURL = configuredReturn("STRIPE_CHECKOUT_SUCCESS_URL") ?? "\(returnBase)/payments/checkout/return"
        checkoutCancelURL = configuredReturn("STRIPE_CHECKOUT_CANCEL_URL") ?? "\(returnBase)/payments/checkout/return"
        guard ((mode == "sandbox" && secretKey.hasPrefix("sk_test_") && publishableKey.hasPrefix("pk_test_")) ||
               (mode == "production" && secretKey.hasPrefix("sk_live_") && publishableKey.hasPrefix("pk_live_"))),
              webhookSecret.hasPrefix("whsec_"), (50...99_999_999).contains(maximumMinor) else {
            throw Abort(.serviceUnavailable, reason: "Stripe top-ups are not configured for \(mode). Check \(prefix)_SECRET_KEY, \(prefix)_PUBLISHABLE_KEY and \(prefix)_WEBHOOK_SECRET.")
        }
    }

    func checkoutReturnURLs(topUpID: String) throws -> (success: String, cancel: String) {
        func validated(_ value: String?) throws -> String {
            guard let value = value,
                  var url = URLComponents(string: value), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.scheme == "https" || (!livemode && url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
                throw Abort(.serviceUnavailable, reason: "Set STRIPE_CHECKOUT_SUCCESS_URL and STRIPE_CHECKOUT_CANCEL_URL to your app's HTTPS return pages (localhost HTTP is allowed in sandbox).")
            }
            var query = url.queryItems ?? []
            query.removeAll { $0.name == "top_up_id" }
            query.append(URLQueryItem(name: "top_up_id", value: topUpID))
            url.queryItems = query
            return url.string!
        }
        return try (validated(checkoutSuccessURL), validated(checkoutCancelURL))
    }
}

struct TeamStripeIntent: Decodable {
    let id: String
    let amount: Int
    let amount_received: Int
    let currency: String
    let status: String
    let livemode: Bool
    let client_secret: String?
    let metadata: [String: String]
    let latest_charge: Charge?
    let last_payment_error: PaymentError?

    struct PaymentError: Decodable { let code: String? }

    struct Charge: Decodable {
        let id: String
        let created: Double?
        let balance_transaction: BalanceTransaction?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let id = try? value.decode(String.self) { self.id = id; created = nil; balance_transaction = nil }
            else {
                let object = try decoder.container(keyedBy: CodingKeys.self)
                id = try object.decode(String.self, forKey: .id)
                created = try object.decodeIfPresent(Double.self, forKey: .created)
                // An unexpanded ID or a not-yet-created transaction means fees are still pending.
                balance_transaction = try? object.decode(BalanceTransaction.self, forKey: .balance_transaction)
            }
        }
        enum CodingKeys: String, CodingKey { case id, created, balance_transaction }
    }

    struct BalanceTransaction: Decodable {
        let id: String
        let amount: Int
        let currency: String
        let fee: Int
        let net: Int

        func validate(amountMinor: Int) throws {
            guard id.hasPrefix("txn_"), currency == "eur", amount == amountMinor,
                  fee >= 0, fee < amount, net == amount - fee else {
                throw Abort(.conflict, reason: "Stripe fee transaction does not match this EUR payment. Contact support.")
            }
        }
    }

    func validate(for topUp: TeamTopUp) throws {
        guard id.hasPrefix("pi_"), amount == topUp.amountMinor,
              currency == "eur", livemode == topUp.livemode,
              metadata["kind"] == "oekfb_team_top_up", metadata["top_up_id"] == topUp.id,
              metadata["team_id"] == topUp.teamID.uuidString,
              topUp.paymentIntentID == nil || topUp.paymentIntentID == id,
              status != "succeeded" || amount_received == topUp.amountMinor else {
            throw Abort(.conflict, reason: "Stripe payment does not match the stored team top-up.")
        }
    }
}

struct TeamStripeCheckoutSession: Decodable {
    let id: String
    let mode: String
    let amount_total: Int?
    let currency: String?
    let livemode: Bool
    let client_reference_id: String?
    let metadata: [String: String]
    let status: String
    let payment_status: String
    let payment_intent: TeamStripeIntent.Charge? // Stripe expandable ID; only the id is used.
    let url: String?
    let expires_at: Double

    func validate(for topUp: TeamTopUp) throws {
        guard topUp.flow == .checkout, id.hasPrefix("cs_"), mode == "payment",
              amount_total == topUp.amountMinor, currency == "eur", livemode == topUp.livemode,
              client_reference_id == topUp.id, metadata["kind"] == "oekfb_team_top_up",
              metadata["top_up_id"] == topUp.id, metadata["team_id"] == topUp.teamID.uuidString,
              topUp.checkoutSessionID == nil || topUp.checkoutSessionID == id,
              payment_intent == nil || topUp.paymentIntentID == nil || topUp.paymentIntentID == payment_intent?.id,
              ["open", "complete", "expired"].contains(status),
              ["paid", "unpaid", "no_payment_required"].contains(payment_status) else {
            throw Abort(.conflict, reason: "Stripe Checkout Session does not match the stored team top-up.")
        }
    }
}

struct TeamStripeClient {
    let client: Client
    let configuration: TeamStripeConfiguration

    func create(_ topUp: TeamTopUp) async throws -> TeamStripeIntent {
        let fields = [
            ("amount", String(topUp.amountMinor)), ("currency", "eur"),
            ("payment_method_types[]", "card"),
            ("metadata[kind]", "oekfb_team_top_up"), ("metadata[top_up_id]", topUp.id),
            ("metadata[team_id]", topUp.teamID.uuidString),
            ("description", "ÖKFB Guthaben Einzahlung – \(topUp.teamName)"),
            ("receipt_email", topUp.recipient), ("expand[]", "latest_charge")
        ]
        let response = try await client.post("https://api.stripe.com/v1/payment_intents") { req in
            headers(&req.headers)
            req.headers.replaceOrAdd(name: "Idempotency-Key", value: "oekfb-topup-\(topUp.id)")
            req.headers.contentType = .urlEncodedForm
            req.body = ByteBuffer(string: Self.form(fields))
        }.get()
        return try decode(response)
    }

    func retrieve(_ id: String) async throws -> TeamStripeIntent {
        guard id.range(of: "^pi_[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid Stripe payment ID.")
        }
        let response = try await client.get(URI(string: "https://api.stripe.com/v1/payment_intents/\(id)?expand%5B%5D=latest_charge.balance_transaction")) { req in
            headers(&req.headers)
        }.get()
        return try decode(response)
    }

    func createCheckout(_ topUp: TeamTopUp) async throws -> TeamStripeCheckoutSession {
        guard let success = topUp.checkoutSuccessURL, let cancel = topUp.checkoutCancelURL else {
            throw Abort(.serviceUnavailable, reason: "Checkout return URLs are missing from this top-up.")
        }
        let fields = [
            ("mode", "payment"), ("payment_method_types[]", "card"),
            ("success_url", success), ("cancel_url", cancel),
            ("client_reference_id", topUp.id), ("customer_email", topUp.recipient),
            ("line_items[0][price_data][currency]", "eur"),
            ("line_items[0][price_data][unit_amount]", String(topUp.amountMinor)),
            ("line_items[0][price_data][product_data][name]", "ÖKFB Guthaben Einzahlung – \(topUp.teamName)"),
            ("line_items[0][quantity]", "1"),
            ("metadata[kind]", "oekfb_team_top_up"), ("metadata[top_up_id]", topUp.id),
            ("metadata[team_id]", topUp.teamID.uuidString),
            ("payment_intent_data[metadata][kind]", "oekfb_team_top_up"),
            ("payment_intent_data[metadata][top_up_id]", topUp.id),
            ("payment_intent_data[metadata][team_id]", topUp.teamID.uuidString),
            ("payment_intent_data[description]", "ÖKFB Guthaben Einzahlung – \(topUp.teamName)"),
            ("payment_intent_data[receipt_email]", topUp.recipient)
        ]
        let response = try await client.post("https://api.stripe.com/v1/checkout/sessions") { req in
            headers(&req.headers)
            req.headers.replaceOrAdd(name: "Idempotency-Key", value: "oekfb-checkout-\(topUp.id)")
            req.headers.contentType = .urlEncodedForm
            req.body = ByteBuffer(string: Self.form(fields))
        }.get()
        return try decode(response)
    }

    func retrieveCheckout(_ id: String) async throws -> TeamStripeCheckoutSession {
        guard id.range(of: "^cs_[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid Stripe Checkout Session ID.")
        }
        let response = try await client.get(URI(string: "https://api.stripe.com/v1/checkout/sessions/\(id)")) { req in
            headers(&req.headers)
        }.get()
        return try decode(response)
    }

    private func headers(_ headers: inout HTTPHeaders) {
        headers.bearerAuthorization = BearerAuthorization(token: configuration.secretKey)
        // Pin the payload contract rather than inheriting future Dashboard changes.
        headers.replaceOrAdd(name: "Stripe-Version", value: "2024-06-20")
    }

    private func decode<T: Decodable>(_ response: ClientResponse) throws -> T {
        guard response.status == .ok, let body = response.body else {
            // Stripe/API/network failures remain recoverable; never log response bodies or client secrets.
            throw Abort(.badGateway, reason: "Stripe payment request could not be completed. Retry with the same idempotency key.")
        }
        return try JSONDecoder().decode(T.self, from: Data(body.readableBytesView))
    }

    static func form(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
    }

    static func verifySignature(body: Data, header: String, secret: String, now: Date = Date()) throws {
        let components = header.split(separator: ",").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        guard let time = components.first(where: { $0.count == 2 && $0[0] == "t" }).flatMap({ Int($0[1]) }),
              abs(now.timeIntervalSince1970 - Double(time)) <= 300 else {
            throw Abort(.badRequest, reason: "Expired or invalid Stripe signature.")
        }
        var signed = Data("\(time).".utf8); signed.append(body)
        let valid = components.filter { $0.count == 2 && $0[0] == "v1" }.contains { part in
            let hex = part[1]
            guard hex.count == 64 else { return false }
            var bytes = [UInt8](); var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<end], radix: 16) else { return false }
                bytes.append(byte); index = end
            }
            return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: signed, using: SymmetricKey(data: Data(secret.utf8)))
        }
        guard valid else { throw Abort(.badRequest, reason: "Invalid Stripe signature.") }
    }
}
