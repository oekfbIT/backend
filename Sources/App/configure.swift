import Vapor
import Fluent
import FluentMongoDriver
import Leaf
import Smtp
import SwiftSoup
import Queues
import QueuesMongoDriver
import MongoKitten

extension String {
    var bytes: [UInt8] { .init(self.utf8) }
}

// Configures your application
public func configure(_ app: Application) throws {
    // Uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
    
    // MARK: - Server Configuration
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "8080") ?? 8080
    
    // MARK: - Database Configuration
    let databaseURL = Environment.get("CONNECTION_STRING") ?? ENV.databaseURL.dev_default
    
    // Adjust database URL based on whether it is local or remote (e.g., DigitalOcean)
    var mongoConnectionString = databaseURL
    if mongoConnectionString.contains("digitalocean") {
        if !mongoConnectionString.contains("authSource") {
            mongoConnectionString += "?authSource=admin"
        }
    }
    
    app.logger.info("Connecting to MongoDB at: \(mongoConnectionString)")
    
    try app.databases.use(.mongo(connectionString: mongoConnectionString), as: .mongo)
    
    
    // MARK: - Leaf Configuration
    app.views.use(.leaf)
    
    // MARK: - Middleware Configuration
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    app.passwords.use(.bcrypt)
    
    // MARK: - MongoKitten Configuration
    do {
        let mongoDatabase = try MongoDatabase.connect(mongoConnectionString, on: app.eventLoopGroup.next()).wait()
        try app.queues.use(.mongodb(mongoDatabase))
    } catch {
        app.logger.error("Failed to connect to MongoDB: \(error.localizedDescription)")
        fatalError("Failed to connect to MongoDB")
    }
    
    app_migrations.forEach { app.migrations.add($0) }
    try app.autoMigrate().wait()
    
    // Configure multiple allowed origins
    let allowedOrigins: [String] = [
        // Localhost variations
        "http://localhost",
        "http://localhost:1234",
        "http://localhost:3000",
        "http://localhost:4000",
        "http://localhost:4001",
        "http://localhost:4500",
        "http://localhost:5500",
        "http://localhost:8081",
        
        // Homepage on DigitalOcean
        "https://homepage-kbe6d.ondigitalocean.app",

        // OEKFB API
        "https://api.oekfb.eu",
        "http://api.oekfb.eu",

        // Admin OEKFB
        "https://admin.oekfb.eu",
        "http://admin.oekfb.eu",
        "https://admin.oekfb.eu:3000",
        "http://admin.oekfb.eu:3000",

        // Admin OEKFB
        "https://admin-owggu.ondigitalocean.app",
        "https://admin-owggu.ondigitalocean.app",
        "https://admin-owggu.ondigitalocean.app:3000",

        // Test OEKFB
        "https://test.oekfb.eu",
        "http://test.oekfb.eu",
        "http://test.oekfb.eu:3000",
        
        // ref OEKFB
        "https://referee-8845q.ondigitalocean.app",
        "https://referee-8845q.ondigitalocean.app:3000",

        // OEKFB main domain
        "https://oekfb.eu",
        "http://oekfb.eu",
        "https://oekfb.eu:3000",
        "http://oekfb.eu:3000",
        "https://oekfb.eu:4000",
        "http://oekfb.eu:4000",

        // www OEKFB
        "https://www.oekfb.eu",
        "http://www.oekfb.eu",

        // Team OEKFB
        "https://team.oekfb.eu",
        "http://team.oekfb.eu",

        // Referee OEKFB
        "https://ref.oekfb.eu",

        // Server IP 165.232.91.105
        "http://165.232.91.105",
        "https://165.232.91.105",
        "http://165.232.91.105:3000",
        "https://165.232.91.105:3000",
        "http://165.232.91.105:4000",
        "https://165.232.91.105:4000",
        "http://165.232.91.105:5000",
        "https://165.232.91.105:5000",
        "https://165.232.91.105:8080",
        "https://165.232.91.105:8081",

        // Server IP 84.115.221.22
        "http://84.115.221.22",
        "https://84.115.221.22",
        "http://84.115.221.22:3000",
        "https://84.115.221.22:3000",
        "http://84.115.221.22:4000",
        "https://84.115.221.22:4000",
        "http://84.115.221.22:5000",
        "https://84.115.221.22:5000",

        // Local Network IPs
        "http://192.168.0.144:3000",
        "http://192.168.0.144:4000",
        "http://192.168.0.242"
    ]

    let corsMiddleware = CustomCORSMiddleware(
        allowedOrigins: allowedOrigins,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            "Authorization",
            "Content-Type",
            "Accept",
            "Origin",
            "X-Requested-With",
            "User-Agent",
            "sec-ch-ua",
            "sec-ch-ua-mobile",
            "sec-ch-ua-platform"
        ],
        allowCredentials: true
    )
        
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    app.middleware.use(corsMiddleware) // Move this after ErrorMiddleware
    
    
    // MARK: - FIREBASE Configuration
//    guard let FIREBASE_APIKEY = Environment.get("FIREBASE_APIKEY") else {
//        fatalError("FIREBASE_APIKEY not set in environment variables")
//    }
//
//    guard let FIREBASE_EMAIL = Environment.get("FIREBASE_EMAIL") else {
//        fatalError("FIREBASE_EMAIL not set in environment variables")
//    }
//
//    guard let FIREBASE_PASSWORD = Environment.get("FIREBASE_PASSWORD") else {
//        fatalError("FIREBASE_PASSWORD not set in environment variables")
//    }
//
//    guard let FIREBASE_PROJECTID = Environment.get("FIREBASE_PROJECTID") else {
//        fatalError("FIREBASE_PROJECTID not set in environment variables")
//    }

    let FIREBASE_APIKEY = Environment.get("FIREBASE_APIKEY") ?? ""
    let FIREBASE_EMAIL = Environment.get("FIREBASE_EMAIL") ?? ""
    let FIREBASE_PASSWORD = Environment.get("FIREBASE_PASSWORD") ?? ""
    let FIREBASE_PROJECTID = Environment.get("FIREBASE_PROJECTID") ?? ""

    let firebaseManager = FirebaseManager(
        client: app.client,
        apiKey: FIREBASE_APIKEY,
        email: FIREBASE_EMAIL,
        password: FIREBASE_PASSWORD,
        projectId: FIREBASE_PROJECTID
    )
    
    app.firebaseManager = firebaseManager

    
    let mongoDatabase = try MongoDatabase.connect(mongoConnectionString, on: app.eventLoopGroup.next()).wait()
    
    app.queues.schedule(UnlockPlayerJob())
        .weekly()
        .on(.monday)
        .at(8,0)
    
    app.queues.schedule(DressLockJob())
        .weekly()
        .on(.thursday)
        .at(23, 0)
    
    app.queues.schedule(DressUnlockJob())
        .weekly()
        .on(.monday)
        .at(6, 0)
    
    
    // Test JOBS
    app.queues.schedule(UnlockPlayerJob())
        .weekly()
        .on(.wednesday)
        .at(13, 30)
    
    // Start the scheduled jobs
    try app.queues.startScheduledJobs()
    
    app.routes.defaultMaxBodySize = "100mb" // Adjust the value as needed
    // Register routes
    try routes(app)
}

