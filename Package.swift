// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideA",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SideA", targets: ["SideA"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "SideACore"),
        .executableTarget(name: "SideA", dependencies: ["SideACore", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "SideACoreTests", dependencies: ["SideACore"]),
        .testTarget(name: "SideATests", dependencies: ["SideA"])
    ]
)
