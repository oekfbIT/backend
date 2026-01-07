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
    let routes: [RouteCollection] = [
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
        HomepageController(path: "client"),
        ClientController(path: "webClient"),
        PostponeRequestController(path: "postpone"),
        SponsorController(path: "sponsor"),
        AppController(path: "app"),
]
    
    app.get("status") { req async -> String in
        "Status Online!"
    }
    
    let emailController = EmailController()
    app.get("sendTestEmail", use: emailController.sendTestEmail)
    
    
    let scraperController = ScraperController()
    app.get("scraper", "league", ":id") { req -> EventLoopFuture<HTTPStatus> in
        try scraperController.scrapeLeagueDetails(req: req)
    }
    
    do {
        try routes.forEach { try app.register(collection: $0) }
    } catch {
        print("Routes couldn't be initialized!")
    }
}


