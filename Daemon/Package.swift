// swift-tools-version: 6.0
import PackageDescription

// The headless Side A daemon (docs/ports/windows-linux-prd.md). It lives in its own package so that SwiftNIO, NIOSSL and
// swift-certificates are not in the Mac app's or the iOS app's dependency graph: `swift build` at the repository root and
// Xcode never see them. It builds on Linux, which it is for, and on macOS, where the same server is easy to run.
let package = Package(
    name: "SideADaemon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sidead", targets: ["sidead"]),
        .library(name: "SideADaemonKit", targets: ["SideADaemonKit"]),
    ],
    dependencies: [
        // The repository root (SideACore re-exports SideAProtocol, so that package comes with it), through a symlink named for it so the package identity is "side-a" in any checkout
        // (a path dependency's identity is its directory name, and worktrees and CI directories are named anything).
        .package(path: "Dependencies/side-a"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "SideADaemonKit", dependencies: [
            .product(name: "SideACore", package: "side-a"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .executableTarget(name: "sidead", dependencies: ["SideADaemonKit"]),
        .testTarget(name: "SideADaemonTests", dependencies: [
            "SideADaemonKit",
            .product(name: "SideACore", package: "side-a"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
