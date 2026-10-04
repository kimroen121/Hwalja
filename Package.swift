// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libhwp_engine_abi.a is produced by `make engine` (Rust) before `swift build`.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "HwpStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CHwpEngine", path: "Engine/include"),
        .executableTarget(
            name: "HwpStudio",
            dependencies: ["CHwpEngine"],
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
