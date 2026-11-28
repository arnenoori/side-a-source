// swift-tools-version: 6.0
import PackageDescription

// A manifest runs on the machine that builds. On a Mac this is the app: Sparkle, the helpers and unsafe linker flags.
// Anywhere else (Linux) it is what is portable: SideACore with swift-crypto, and its tests. The Linux dependencies are
// not declared on a Mac, so the Mac app's dependency graph and Package.resolved stay as they were.
#if os(macOS)
let platformDependencies: [Package.Dependency] = [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")]
let coreDependencies: [Target.Dependency] = [.product(name: "SideAProtocol", package: "SideAProtocol")]
let coreTestDependencies: [Target.Dependency] = ["SideACore", "SideAKeepAwakeCore"]
let appTargets: [Target] = [
    .target(name: "SideAKeepAwakeCore"),
    .target(name: "CSideAPTY"),
    .executableTarget(name: "SideAKeepAwake", dependencies: ["SideAKeepAwakeCore"]),
    .executableTarget(name: "SideAPool", dependencies: ["SideACore"]),
    .executableTarget(name: "SideA", dependencies: ["SideACore", "SideAKeepAwakeCore", "CSideAPTY", .product(name: "Sparkle", package: "Sparkle"),
                                                    .product(name: "SideARemoteKit", package: "SideAProtocol"),
                                                    .product(name: "SideASessionKit", package: "SideAProtocol")],
                      resources: [.process("Resources")],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "SideATests", dependencies: ["SideA", .product(name: "SideAProtocolFixtures", package: "SideAProtocol"),
                                                  .product(name: "SideARemoteKit", package: "SideAProtocol")],
                // Scripts the tests copy into a tmux pane; read by path, not bundled.
                exclude: ["Fixtures"]),
]
let appProducts: [Product] = [
    .executable(name: "SideA", targets: ["SideA"]),
    .executable(name: "SideAKeepAwake", targets: ["SideAKeepAwake"]),
    .executable(name: "SideAPool", targets: ["SideAPool"]),
]
#else
let platformDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1")]
let coreDependencies: [Target.Dependency] = [.product(name: "SideAProtocol", package: "SideAProtocol"), .product(name: "Crypto", package: "swift-crypto")]
let coreTestDependencies: [Target.Dependency] = ["SideACore"]
let appTargets: [Target] = []
let appProducts: [Product] = []
#endif

let package = Package(
    name: "SideA",
    platforms: [.macOS(.v14)],
    products: appProducts + [.library(name: "SideACore", targets: ["SideACore"])],
    dependencies: [.package(path: "Packages/SideAProtocol")] + platformDependencies,
    targets: [
        .target(name: "SideACore", dependencies: coreDependencies),
        .testTarget(name: "SideACoreTests", dependencies: coreTestDependencies),
    ] + appTargets
)
