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

    try app.databases.use(.mongo(connectionString: Environment.get(ENV.databaseURL.key) ?? ENV.databaseURL.dev_default),
                          as: .mongo)
 
    app_migrations.forEach { app.migrations.add($0) }
    
    try app.autoMigrate().wait()
 
    app.views.use(.leaf)
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    app.passwords.use(.bcrypt)

    // Configure multiple allowed origins
    let allowedOrigins: [String] = [
        "https://homepage-kbe6d.ondigitalocean.app",
        "https://api.oekfb.eu",
        "http://api.oekfb.eu",
        "http://localhost",
        "http://localhost:1234",
        "http://localhost:3000",
        "http://localhost:4000",
        "http://localhost:4001",
        "http://localhost:5500",
        "http://localhost:4500",
        "https://admin.oekfb.eu",
        "http://admin.oekfb.eu:3000",
        "https://admin.oekfb.eu:3000",
        "http://admin.oekfb.eu",
        "https://oekfb.eu:3000",
        "https://oekfb.eu:4000",
        "https://oekfb.eu",
        "http://oekfb.eu:3000",
        "http://oekfb.eu:4000",
        "http://oekfb.eu",
        "https://www.oekfb.eu",
        "http://www.oekfb.eu",
        "http://team.oekfb.eu",
        "https://team.oekfb.eu",
        "https://ref.oekfb.eu",
        "http://165.232.91.105:3000",
        "http://165.232.91.105:4000",
        "http://165.232.91.105:5000",
        "http://165.232.91.105",
        "https://165.232.91.105:3000",
        "https://165.232.91.105:4000",
        "https://165.232.91.105:5000",
        "https://165.232.91.105",
        "http://84.115.221.22",
        "http://84.115.221.22:3000",
        "http://84.115.221.22:4000",
        "http://84.115.221.22:5000",
        "https://84.115.221.22",
        "https://84.115.221.22:3000",
        "https://84.115.221.22:4000",
        "https://84.115.221.22:5000",
        "http://192.168.0.144:4000",
        "http://192.168.0.144:3000",
        "http://192.168.0.242"
    ]

    // Initialize the custom CORS middleware
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

    app.middleware.use(corsMiddleware) // CORS should run first
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    let firebaseManager = FirebaseManager(
        client: app.client,
        apiKey: "AIzaSyBHum43yMHxKE15ctAI54LSCmiJ-6uDI8I",
        email: "admin@oekfb.eu",
        password: "hY-q2Giapxzng",
        projectId: "oekfbbucket"
    )
    
    app.firebaseManager = firebaseManager

    // Configure Queues with MongoDB
     let mongoConnectionString = Environment.get(ENV.databaseURL.key) ?? ENV.databaseURL.dev_default
     let mongoDatabase = try MongoDatabase.connect(mongoConnectionString, on: app.eventLoopGroup.next()).wait()
     
     // Setup Queues with MongoDB driver
     try app.queues.use(.mongodb(mongoDatabase))
     
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

     // Register routes
     try routes(app)
 }
