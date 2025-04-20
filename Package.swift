// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMSCureSDK",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
        .tvOS(.v13),
        .watchOS(.v7)
    ],
    products: [
        .library(name: "CMSCureSDK", targets: ["CMSCureSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.0.1")
    ],
    targets: [
        .target(
            name: "CMSCureSDK",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ]
        )
    ]
)
