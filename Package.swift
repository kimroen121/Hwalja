// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libhwp_engine_abi.a is produced by `make engine` (Rust) before `swift build`.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Hwalja",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", revision: "1d2c90827e9c3908269d810d055fb03b7da5fd53"),
    ],
    targets: [
        .systemLibrary(name: "CHwpEngine", path: "Engine/include"),
        .executableTarget(
            name: "Hwalja",
            dependencies: ["CHwpEngine", "SwiftMath"],
            path: "App",
            exclude: ["Resources"],
            linkerSettings: [.unsafeFlags(["-L\(root)/build"])]
        ),
        .testTarget(
            name: "HwaljaTests",
            dependencies: ["Hwalja"],
            path: "Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
