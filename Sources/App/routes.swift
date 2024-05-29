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
        TeamController(path: "teams"), // Index fine
        PlayerController(path: "players"), // NOT WORKING
        LeagueController(path: "leagues"), //Index fine
        SeasonController(path: "seasons"), // Index fine -> League Missing
        StadiumController(path: "stadiums"), // Index fine
        MatchController(path: "matches"), // Index fine
        MatchEventController(path: "events"), // Events
        RefereeController(path: "referees"),
    ]
    
    app.get("status") { req async -> String in
        "Status Online!"
    }
    
    // MAIL CONTROLLER
    let emailController = EmailController()
    app.get("sendTestEmail", use: emailController.sendTestEmail)

    
    do {
        try routes.forEach { try app.register(collection: $0) }
    } catch {
        print("Routes couldn't be initialized!")
    }
}


    let mailConfig = EmailConfiguration(hostname: "smtp.easyname.com",
                                        email: "admin@oekfb.eu",
                                        password: "Oekfb$2024")




