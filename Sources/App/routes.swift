//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Fluent
import Vapor
import Leaf

func routes(_ app: Application) throws {
    // Only deliberately public, response-shaped controllers belong here. Database
    // model CRUD controllers must never be registered directly on `app` because
    // Fluent models contain private fields (emails, ID documents, balances, etc.).
    let publicRoutes: [RouteCollection] = [
        HomepageController(path: "client"),
        ClientController(path: "webClient"),
        TeamPaymentController(),
        AppController(path: "app"),
        AdminController(path: "admin"),
        LegalDocumentController(path: "legal")
    ]

    // Legacy/root CRUD endpoints are retained for administrator compatibility,
    // but are now protected as one fail-closed group.
    let adminOnlyRoutes: [RouteCollection] = [
        UserController(path: "users"),
        TeamController(path: "teams"),
        PlayerController(path: "players"),
        LeagueController(path: "leagues"),
        SeasonController(path: "seasons"),
        StadiumController(path: "stadiums"),
        MatchController(path: "matches"),
        MatchEventController(path: "events"),
        RefereeController(path: "referees"),
        TeamRegistrationController(path: "registrations"),
        ConversationController(path: "chat"),
        NewsController(path: "news"),
        RechnungsController(path: "finanzen"),
        ScraperDetailController(),
        TransferController(path: "transfers"),
        TransferSettingsController(path: "transferSettings"),
        StrafsenatController(path: "strafsenat"),
        SponsorController(path: "sponsor"),
        PeopleEventController(path: "people-events")
    ]

    // Team postponement remains available to signed-in application users. Its
    // records are no longer anonymously enumerable.
    let authenticatedRoutes: [RouteCollection] = [
        PostponeRequestController(path: "postpone")
    ]
    
    app.get("status") { req async -> String in
        "Status Online!"
    }
    
    let protected = app.grouped(
        Token.authenticator(),
        User.guardMiddleware(),
        ProtectedResponseMiddleware()
    )
    let adminOnly = protected.grouped(AdminOnlyMiddleware())

    let emailController = EmailController()
    adminOnly.get("sendTestEmail", use: emailController.sendTestEmail)

    let scraperController = ScraperController()
    adminOnly.get("scraper", "league", ":id") { req -> EventLoopFuture<HTTPStatus> in
        try scraperController.scrapeLeagueDetails(req: req)
    }

    try publicRoutes.forEach { try app.register(collection: $0) }
    try authenticatedRoutes.forEach { try $0.boot(routes: protected) }
    try adminOnlyRoutes.forEach { try $0.boot(routes: adminOnly) }
}
