// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "oekfbbackend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.94.1"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.8.0"),
        // Fluent driver for Mongo.
        .package(url: "https://github.com/vapor/fluent-mongo-driver.git", from: "1.0.0"),
        // 🍃 An expressive, performant, and extensible templating language built for Swift.
        .package(url: "https://github.com/vapor/leaf.git", from: "4.2.4"),
        // 📧 A package for sending emails.
        .package(url: "https://github.com/Kitura/Swift-SMTP", .upToNextMinor(from: "5.1.0")),
        // 🔒 SSL Service for Kitura.
        .package(url: "https://github.com/Kitura/BlueSSLService.git", from: "1.0.200")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMongoDriver", package: "fluent-mongo-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "SwiftSMTP", package: "Swift-SMTP"),
                .product(name: "SSLService", package: "BlueSSLService")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor")
            ]
        )
    ]
)
