import Fluent
import FluentMongoDriver
import Leaf
import Vapor

extension String {
    var bytes: [UInt8] { .init(self.utf8) }
}

// configures your application
public func configure(_ app: Application) throws {
    // uncomment to serve files from /Public folder
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
        "http://localhost",
        "http://localhost:3000",
        "http://localhost:4000",
        "http://localhost:5000",
        
        "https://admin.oekfb.eu",
        
        "https://oekfb.eu:3000",
        "https://oekfb.eu:4000",
        "https://oekfb.eu",

        "http://oekfb.eu:3000",
        "http://oekfb.eu:4000",
        "http://oekfb.eu",
        
        "https://www.oekfb.eu",
        "http://www.oekfb.eu",

        "https://team.oekfb.eu",
        "https://ref.oekfb.eu",
        
        "http://165.232.91.105:3000",
        "http://165.232.91.105:4000/",
        "http://165.232.91.105:5000/",
        "http://165.232.91.105/",
        
        "https://165.232.91.105:3000",
        "https://165.232.91.105:4000/",
        "https://165.232.91.105:5000/",
        "https://165.232.91.105/",

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

    // CORS configuration
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .any(allowedOrigins),
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.authorization, .contentType, .accept, .origin, .xRequestedWith, .userAgent, .init("sec-ch-ua"), .init("sec-ch-ua-mobile"), .init("sec-ch-ua-platform")],
        allowCredentials: true,
        exposedHeaders: [.authorization, .contentType]
    )

    let corsMiddleware = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(corsMiddleware, at: .beginning) // Ensure it's the first middleware to run

    
    let firebaseManager = FirebaseManager(
        client: app.client,
        apiKey: "AIzaSyBHum43yMHxKE15ctAI54LSCmiJ-6uDI8I",
        email: "admin@oekfb.eu",
        password: "hY-q2Giapxzng",
        projectId: "oekfbbucket"
    )
    
    app.firebaseManager = firebaseManager

    // register routes
    try routes(app)
}
