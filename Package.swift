// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "CMSCureSDK",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "CMSCureSDK",
            targets: ["CMSCureSDK"]),
    ],
    dependencies: [
        // Existing dependency
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.0.1"),
        // NEW: Add Kingfisher dependency
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "CMSCureSDK",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                // NEW: Make the SDK target depend on Kingfisher
                .product(name: "Kingfisher", package: "Kingfisher")
            ],
            path: "Sources/CMSCureSDK"
        ),
    ]
)
