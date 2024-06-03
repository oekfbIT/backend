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
    ]
    
    app.get("status") { req async -> String in
        "Status Online!"
    }
    
    let emailController = EmailController()
    app.get("sendTestEmail", use: emailController.sendTestEmail)
    
    do {
        try routes.forEach { try app.register(collection: $0) }
    } catch {
        print("Routes couldn't be initialized!")
    }
}


