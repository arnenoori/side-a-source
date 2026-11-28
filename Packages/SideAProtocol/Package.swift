// swift-tools-version: 6.0
import PackageDescription

// A manifest runs on the machine that builds, so `os(macOS)` here means "an Apple build": Xcode and `swift build` on a
// Mac. Everything Linux needs is added only when the host is not a Mac, so the Apple dependency graph (and the iOS
// app's) does not grow, and SideARemoteKit (Network.framework) and SideASessionKit (SwiftUI) are left out of Linux builds.
#if os(macOS)
let cryptoDependencies: [Package.Dependency] = []
let cryptoProducts: [Target.Dependency] = []
let remoteKit: [Target] = [
    .target(name: "SideARemoteKit", dependencies: ["SideAProtocol"]),
    .testTarget(name: "SideARemoteKitTests", dependencies: ["SideARemoteKit", "SideAProtocolFixtures"]),
    // Session logic and views the Mac app and the phone app share. It knows the wire and nothing of how either app
    // reaches a session, so the Mac links it without the phone's transport.
    .target(name: "SideASessionKit", dependencies: ["SideAProtocol"]),
    .testTarget(name: "SideASessionKitTests", dependencies: ["SideASessionKit", "SideAProtocolFixtures"]),
]
let remoteKitProducts: [Product] = [
    .library(name: "SideARemoteKit", targets: ["SideARemoteKit"]),
    .library(name: "SideASessionKit", targets: ["SideASessionKit"]),
]
#else
let cryptoDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1")]
let cryptoProducts: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
let remoteKit: [Target] = []
let remoteKitProducts: [Product] = []
#endif

let package = Package(
    name: "SideAProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SideAProtocol", targets: ["SideAProtocol"]),
        .library(name: "SideAProtocolFixtures", targets: ["SideAProtocolFixtures"]),
    ] + remoteKitProducts,
    dependencies: cryptoDependencies,
    targets: [
        .target(name: "SideAProtocol", dependencies: cryptoProducts),
        .target(name: "SideAProtocolFixtures", resources: [.copy("Fixtures")]),
        .testTarget(name: "SideAProtocolTests", dependencies: ["SideAProtocol", "SideAProtocolFixtures"] + cryptoProducts),
    ] + remoteKit
)
