// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HubKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "HubKit", targets: ["HubKit"])],
    targets: [
        .target(name: "HubKit"),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit"]),
    ]
)
