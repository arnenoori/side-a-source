// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SideA", targets: ["SideA"]),
        .executable(name: "SideAKeepAwake", targets: ["SideAKeepAwake"]),
        .executable(name: "SideAPool", targets: ["SideAPool"])
    ],
    dependencies: [
        .package(path: "Packages/SideAProtocol"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "SideACore", dependencies: [.product(name: "SideAProtocol", package: "SideAProtocol")]),
        .target(name: "SideAKeepAwakeCore"),
        .target(name: "CSideAPTY"),
        .executableTarget(name: "SideAKeepAwake", dependencies: ["SideAKeepAwakeCore"]),
        .executableTarget(name: "SideAPool", dependencies: ["SideACore"]),
        .executableTarget(name: "SideA", dependencies: ["SideACore", "SideAKeepAwakeCore", "CSideAPTY", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "SideACoreTests", dependencies: ["SideACore", "SideAKeepAwakeCore"]),
        .testTarget(name: "SideATests", dependencies: ["SideA", .product(name: "SideAProtocolFixtures", package: "SideAProtocol"),
                                                      .product(name: "SideARemoteKit", package: "SideAProtocol")])
    ]
)
