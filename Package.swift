// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libhwp_engine_abi.a is produced by `make engine` (Rust) before `swift build`.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "HwpStudio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
    ],
    targets: [
        .systemLibrary(name: "CHwpEngine", path: "Engine/include"),
        .executableTarget(
            name: "HwpStudio",
            dependencies: ["CHwpEngine", "SwiftMath"],
            path: "App",
            exclude: ["Resources"],
            linkerSettings: [.unsafeFlags(["-L\(root)/build"])]
        ),
        .testTarget(
            name: "HwpStudioTests",
            dependencies: ["HwpStudio"],
            path: "Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
