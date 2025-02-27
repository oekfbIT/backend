// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "oekfbbackend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // Existing dependencies...
        .package(url: "https://github.com/vapor/vapor.git", from: "4.94.1"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/fluent-mongo-driver.git", from: "1.0.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.2.4"),
        .package(url: "https://github.com/Mikroservices/Smtp.git", from: "3.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/swiftpackages/DotEnv.git", from: "3.0.0"),
        // Add Queues MongoDB Driver
        .package(url: "https://github.com/vapor-community/queues-mongo-driver.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMongoDriver", package: "fluent-mongo-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Smtp", package: "Smtp"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "DotEnv", package: "DotEnv"),
                // Add Queues MongoDB Driver product
                .product(name: "QueuesMongoDriver", package: "queues-mongo-driver"),
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
