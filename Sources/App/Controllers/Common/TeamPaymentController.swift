import Fluent
import Vapor

struct TeamPaymentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let payments = routes.grouped("payments")
        payments.on(.POST, "stripe", "webhook", body: .collect(maxSize: "256kb"), use: webhook)
        payments.get("checkout", "return", use: checkoutReturn)
        let authed = payments.grouped(
            Token.authenticator(),
            User.guardMiddleware(),
            ProtectedResponseMiddleware()
        )
        authed.get("config", use: config)
        authed.post("teams", ":teamID", "top-ups", use: create)
        authed.post("teams", ":teamID", "top-ups", "checkout", use: createCheckout)
        authed.get("top-ups", ":topUpID", use: status)
        authed.get("top-ups", ":topUpID", "confirmation", use: confirmation)
        authed.get("teams", ":teamID", "invoices", use: invoices)
    }

    static func authorize(team: Team, user: User) throws {
        guard user.type == .admin || (user.type == .team && team.$user.id == user.id) else {
            throw Abort(.forbidden, reason: "This team does not belong to your account.")
        }
    }

    static func team(_ id: UUID, on req: Request) async throws -> Team {
        let user = try req.auth.require(User.self)
        guard let team = try await Team.find(id, on: req.db) else { throw Abort(.notFound) }
        try authorize(team: team, user: user)
        return team
    }

    struct ConfigurationResponse: Content {
        let publishableKey: String
        let currency: String
        let minimumAmountMinor: Int
        let maximumAmountMinor: Int
        let livemode: Bool
        let stripeMode: String
        let checkoutEnabled: Bool
        let paymentsEnabled: Bool
        let creditPolicy: TeamTopUpCreditPolicy
        let estimatedFeeBasisPoints: Int
        let estimatedFeeFixedMinor: Int
    }
    static func paymentsEnabled(on req: Request) async throws -> Bool {
        let settings = try await TransferSettings.query(on: req.db).first()
        return settings?.paymentsEnabled ?? true
    }
    static func requirePaymentsEnabled(on req: Request) async throws {
        guard try await paymentsEnabled(on: req) else {
            throw Abort(.forbidden, reason: "Stripe payments are currently disabled.")
        }
    }
    func config(req: Request) async throws -> ConfigurationResponse {
        guard try await Self.paymentsEnabled(on: req) else {
            return ConfigurationResponse(publishableKey: "", currency: "eur",
                minimumAmountMinor: 1000, maximumAmountMinor: 0, livemode: false, stripeMode: "disabled",
                checkoutEnabled: false, paymentsEnabled: false,
                creditPolicy: .stripeNet, estimatedFeeBasisPoints: 150, estimatedFeeFixedMinor: 25)
        }
        let config = try TeamStripeConfiguration()
        return ConfigurationResponse(publishableKey: config.publishableKey, currency: "eur",
            minimumAmountMinor: 1000, maximumAmountMinor: config.maximumMinor, livemode: config.livemode, stripeMode: config.mode,
            checkoutEnabled: (try? config.checkoutReturnURLs(topUpID: "configuration")) != nil,
            paymentsEnabled: true,
            creditPolicy: .stripeNet, estimatedFeeBasisPoints: 150, estimatedFeeFixedMinor: 25)
    }
    // The redirect is informational only. No payment or personal data is exposed here.
    func checkoutReturn(req: Request) -> Response {
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.body = .init(string: """
        <!doctype html>
        <html lang="de">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>ÖKFB · Zahlungsbestätigung wird erwartet</title>
          <style>
            :root { color-scheme: light dark; }
            * { box-sizing: border-box; }
            body { margin: 0; padding: 40px 24px; background: #f7f8fa; color: #111; font: 16px/1.55 system-ui, sans-serif; }
            main { max-width: 420px; margin: 0 auto; }
            .label { color: #6b7280; font-size: 13px; font-weight: 600; margin-bottom: 24px; }
            h1 { font-size: 28px; line-height: 1.2; margin: 0 0 20px; }
            .hint { padding: 16px; border: 1px solid #e5e7eb; border-radius: 16px; background: #fff; }
            .waiting { display: flex; align-items: center; gap: 14px; }
            .spinner { width: 28px; height: 28px; flex-shrink: 0; border: 3px solid #e5e7eb; border-top-color: #ff8410; border-radius: 50%; animation: spin 1s linear infinite; }
            @keyframes spin { to { transform: rotate(360deg); } }
            @media (prefers-reduced-motion: reduce) { .spinner { animation: none; } }
            .note { color: #6b7280; font-size: 14px; margin-top: 20px; }
            @media (prefers-color-scheme: dark) {
              body { background: #15181c; color: #f9fafb; }
              .hint { background: #20252b; border-color: #374151; }
              .label, .note { color: #c3c8d0; }
            }
          </style>
        </head>
        <body><main>
          <div class="label">ÖKFB · Guthaben aufladen</div>
          <h1>Zahlungsbestätigung wird erwartet</h1>
          <div class="hint waiting" role="status" aria-live="polite">
            <span class="spinner" aria-hidden="true"></span>
            <strong>Warten auf die Bestätigung in der App …</strong>
          </div>
          <p>Bitte warte einen Moment. Die ÖKFB App prüft deine Zahlung und aktualisiert
          dein Guthaben, sobald die Zahlung und die Stripe-Gebühren bestätigt sind.</p>
          <p class="note">Bitte nicht erneut bezahlen. Die Rückkehr von Stripe allein ist noch keine Zahlungsbestätigung.</p>
          <details class="note">
            <summary>Dieses Fenster bleibt geöffnet?</summary>
            <p>Schließe es über das Häkchen oder „Fertig“ oben links. Auf Android verwende die Zurück-Taste.
            In der Finanzübersicht wird die Bestätigung automatisch weiter geprüft.
            Das Schließen bestätigt oder storniert keine Zahlung.</p>
            <p>In einem separaten Browser: Wechsle zurück zur ÖKFB App.</p>
          </details>
        </main></body></html>
        """)
        return response
    }

    func create(req: Request) async throws -> TeamTopUpResponse {
        try await Self.requirePaymentsEnabled(on: req)
        let team = try await Self.team(req.parameters.require("teamID", as: UUID.self), on: req)
        return try await TeamTopUpManager(application: req.application).create(team: team,
            user: req.auth.require(User.self), input: req.content.decode(TeamTopUpInput.self))
    }
    func status(req: Request) async throws -> TeamTopUpResponse {
        let topUp = try await TeamTopUpStore(database: req.db).get(req.parameters.require("topUpID"))
        _ = try await Self.team(topUp.teamID, on: req)
        return TeamTopUpResponse(topUp, publishableKey: try TeamStripeConfiguration().publishableKey)
    }
    func createCheckout(req: Request) async throws -> TeamTopUpResponse {
        try await Self.requirePaymentsEnabled(on: req)
        let team = try await Self.team(req.parameters.require("teamID", as: UUID.self), on: req)
        return try await TeamTopUpManager(application: req.application).create(team: team,
            user: req.auth.require(User.self), input: req.content.decode(TeamTopUpInput.self), flow: .checkout)
    }
    func confirmation(req: Request) async throws -> Response {
        let store = TeamTopUpStore(database: req.db)
        var topUp = try await store.get(req.parameters.require("topUpID"))
        _ = try await Self.team(topUp.teamID, on: req)
        if topUp.creditedAt == nil {
            // Reconcile under the existing worker lease instead of waiting for webhook delivery.
            do {
                try await TeamTopUpManager(application: req.application).process(id: topUp.id)
            } catch {
                req.logger.warning("Top-up confirmation reconciliation deferred")
            }
            topUp = try await store.get(topUp.id)
        }
        let response = Response(status: topUp.confirmationHTTPStatus)
        try response.content.encode(TeamTopUpResponse(topUp,
            publishableKey: try TeamStripeConfiguration().publishableKey, includeSecret: false))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        if response.status == .accepted { response.headers.replaceOrAdd(name: "Retry-After", value: "3") }
        return response
    }
    func invoices(req: Request) async throws -> Page<Rechnung.Public> {
        let team = try await Self.team(req.parameters.require("teamID", as: UUID.self), on: req)
        let query = Rechnung.query(on: req.db).filter(\.$team.$id == team.id)
        if let source = req.query[String.self, at: "source"] {
            guard ["manual", "stripe"].contains(source) else { throw Abort(.badRequest, reason: "source must be manual or stripe.") }
            if source == "stripe" { query.filter(\.$paymentSource == "stripe") }
            else { query.group(.or) { $0.filter(\.$paymentSource == "manual").filter(\.$paymentSource == nil) } }
        }
        let page = max(1, min(100_000, req.query[Int.self, at: "page"] ?? 1))
        let per = max(1, min(100, req.query[Int.self, at: "per"] ?? 20))
        let result = try await query.sort(\.$created, .descending)
            .paginate(PageRequest(page: page, per: per))
        return Page(items: result.items.map { $0.asPublic() }, metadata: result.metadata)
    }
    func webhook(req: Request) async throws -> HTTPStatus {
        guard let bytes = req.body.data, let signature = req.headers.first(name: "Stripe-Signature") else {
            throw Abort(.badRequest, reason: "Stripe webhook body and signature are required.")
        }
        try await TeamTopUpManager(application: req.application).receiveWebhook(
            body: Data(bytes.readableBytesView), signature: signature)
        return .ok
    }
}
