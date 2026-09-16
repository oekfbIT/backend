import Fluent
import Vapor

struct TeamPaymentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let payments = routes.grouped("payments")
        payments.on(.POST, "stripe", "webhook", body: .collect(maxSize: "256kb"), use: webhook)
        payments.get("checkout", "return", use: checkoutReturn)
        let authed = payments.grouped(Token.authenticator(), User.guardMiddleware())
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
        let creditPolicy: TeamTopUpCreditPolicy
        let estimatedFeeBasisPoints: Int
        let estimatedFeeFixedMinor: Int
    }
    func config(req: Request) throws -> ConfigurationResponse {
        let config = try TeamStripeConfiguration()
        return ConfigurationResponse(publishableKey: config.publishableKey, currency: "eur",
            minimumAmountMinor: 1000, maximumAmountMinor: config.maximumMinor, livemode: config.livemode, stripeMode: config.mode,
            checkoutEnabled: (try? config.checkoutReturnURLs(topUpID: "configuration")) != nil,
            creditPolicy: .stripeNet, estimatedFeeBasisPoints: 150, estimatedFeeFixedMinor: 25)
    }
    // The redirect is informational only. No payment or personal data is exposed here.
    func checkoutReturn(req: Request) -> Response {
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.body = .init(string: """
        <!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>ÖKFB · Zahlung prüfen</title><body style="font:18px system-ui;background:#f7f8fa;padding:32px;max-width:480px;margin:auto">
        <h1>Zurück zur ÖKFB App</h1><p>Öffne „Guthaben aufladen“, um den Status deiner Zahlung zu prüfen.
        Dein Guthaben wird erst nach Zahlungsbestätigung und Ermittlung der Stripe-Gebühren aktualisiert.</p>
        <p>Auch nach einem Abbruch prüft die App eine bereits gestartete Zahlung, bevor du erneut zahlst.</p>
        <a href="oekfbapp://" style="display:block;padding:16px;background:#ff8214;color:#111;border-radius:16px;text-align:center">ÖKFB App öffnen</a></body></html>
        """)
        return response
    }

    func create(req: Request) async throws -> TeamTopUpResponse {
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
        let team = try await Self.team(req.parameters.require("teamID", as: UUID.self), on: req)
        return try await TeamTopUpManager(application: req.application).create(team: team,
            user: req.auth.require(User.self), input: req.content.decode(TeamTopUpInput.self), flow: .checkout)
    }
    func confirmation(req: Request) async throws -> Response {
        let topUp = try await TeamTopUpStore(database: req.db).get(req.parameters.require("topUpID"))
        _ = try await Self.team(topUp.teamID, on: req)
        let response = Response(status: topUp.confirmationHTTPStatus)
        try response.content.encode(TeamTopUpResponse(topUp,
            publishableKey: try TeamStripeConfiguration().publishableKey, includeSecret: false))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        if response.status == .accepted { response.headers.replaceOrAdd(name: "Retry-After", value: "3") }
        return response
    }
    func invoices(req: Request) async throws -> Page<Rechnung> {
        let team = try await Self.team(req.parameters.require("teamID", as: UUID.self), on: req)
        let query = Rechnung.query(on: req.db).filter(\.$team.$id == team.id)
        if let source = req.query[String.self, at: "source"] {
            guard ["manual", "stripe"].contains(source) else { throw Abort(.badRequest, reason: "source must be manual or stripe.") }
            if source == "stripe" { query.filter(\.$paymentSource == "stripe") }
            else { query.group(.or) { $0.filter(\.$paymentSource == "manual").filter(\.$paymentSource == nil) } }
        }
        let page = max(1, min(100_000, req.query[Int.self, at: "page"] ?? 1))
        let per = max(1, min(100, req.query[Int.self, at: "per"] ?? 20))
        return try await query.sort(\.$created, .descending).paginate(PageRequest(page: page, per: per))
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
