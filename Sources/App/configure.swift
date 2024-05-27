import Fluent
import FluentMongoDriver
import Leaf
import Vapor
//import JWT

extension String {
    var bytes: [UInt8] { .init(self.utf8) }
}

// configures your application
public func configure(_ app: Application) throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    
    //    app.jwt.signers.use(.hs256(key: "3Cz30pJzxbqYvLjXqTJjU8VpU5bxvgoNRvq1a+BXOts"))
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
    
//    app.jwt.signers.use(.hs256(key: Environment.get(ENV.jwtSecret.key) ?? ENV.jwtSecret.dev_default))

    try app.databases.use(.mongo(connectionString:Environment.get(ENV.databaseURL.key) ?? ENV.databaseURL.dev_default),
                          as: .mongo)
 
    app_migrations.forEach { app.migrations.add($0) }
    
    try app.autoMigrate().wait()
 
    app.views.use(.leaf)
//    app.middleware.use(DBUser.authenticator())
//    app.middleware.use(Token.authenticator())

    
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    app.passwords.use(.bcrypt)

//    // Define your CORS configuration to allow requests from any origin
//    let corsConfiguration = CORSMiddleware.Configuration(
//        allowedOrigin: .all, // Allow all origins
//        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH], // Specify allowed methods
//        allowedHeaders: [.authorization, .contentType, .accept, .origin, .xRequestedWith], // Specify allowed headers
//        allowCredentials: true, // Whether to allow cookies/cross-origin requests
//        exposedHeaders: [.authorization, .contentType] // Optional: Specify headers that browsers are allowed to access
//    )
//
//    // Create the CORS middleware with the configuration
//    let corsMiddleware = CORSMiddleware(configuration: corsConfiguration)

    // Use the CORS middleware in your application
//    app.middleware.use(corsMiddleware, at: .beginning) // Ensure it's the first middleware to run

    // register routes
    try routes(app)
}
