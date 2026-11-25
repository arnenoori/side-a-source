// swift-tools-version: 6.0
import PackageDescription

// A client for sidead, built from the same SideARemoteKit the iPhone app uses (it needs Network.framework, so it builds on a
// Mac only). It pairs, lists sessions, starts a hosted one, replies and watches the transcript: the end-to-end check
// scripts/linux-e2e.sh runs against a sidead in a Linux container.
let package = Package(
    name: "SideAProbe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/SideAProtocol")],
    targets: [
        .executableTarget(name: "sidea-probe", dependencies: [
            .product(name: "SideARemoteKit", package: "SideAProtocol"),
            .product(name: "SideAProtocol", package: "SideAProtocol"),
        ]),
    ]
)
