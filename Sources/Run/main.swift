//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import App
import Vapor

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

let app = Application(env)
defer { app.shutdown() }

app.smtp.configuration.hostname = "smtp.easyname.com"
app.smtp.configuration.signInMethod = .credentials(username: "admin@oekfb.eu", password: "Oekfb$2024")
app.smtp.configuration.port = 465
app.smtp.configuration.secure = .startTls

try configure(app)
try app.run()


//app.smtp.configuration.host = "smtp.easyname.com"
//app.smtp.configuration.signInMethod = .credentials(username: "admin@oekfb.eu", password: "Oekfb$2024")
//app.smtp.configuration.secure = .ssl
