// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideAProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SideAProtocol", targets: ["SideAProtocol"]),
        .library(name: "SideARemoteKit", targets: ["SideARemoteKit"]),
        .library(name: "SideAProtocolFixtures", targets: ["SideAProtocolFixtures"]),
    ],
    targets: [
        .target(name: "SideAProtocol"),
        .target(name: "SideARemoteKit", dependencies: ["SideAProtocol"]),
        .target(name: "SideAProtocolFixtures", resources: [.copy("Fixtures")]),
        .testTarget(name: "SideAProtocolTests", dependencies: ["SideAProtocol", "SideAProtocolFixtures"]),
        .testTarget(name: "SideARemoteKitTests", dependencies: ["SideARemoteKit", "SideAProtocolFixtures"]),
    ]
)
