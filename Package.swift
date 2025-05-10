// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "CMSCureSDK",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "CMSCureSDK",
            targets: ["CMSCureSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.0.1")
    ],
    targets: [
        .target(
            name: "CMSCureSDK",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ],
            path: "Sources/CMSCureSDK"
        ),
    ]
)
