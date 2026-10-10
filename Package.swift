// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libhwp_engine_abi.a is produced by `make engine` (Rust) before `swift build`.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Hwalja",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hwalja", targets: ["Hwalja"]),
        .executable(name: "HwaljaPreview", targets: ["HwaljaPreview"]),
        // Its own scheme in Xcode; select it to use #Preview (the executables can't host previews).
        .library(name: "HwaljaKit", type: .dynamic, targets: ["HwaljaKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", revision: "1d2c90827e9c3908269d810d055fb03b7da5fd53"),
    ],
    targets: [
        .systemLibrary(name: "CHwpEngine", path: "Engine/include"),
        // The app's code, a library so Xcode can build its #Previews.
        .target(
            name: "HwaljaKit",
            dependencies: ["CHwpEngine", "SwiftMath"],
            path: "App",
            exclude: ["Resources", "Main"],
            linkerSettings: [.unsafeFlags(["-L\(root)/build"])]
        ),
        .executableTarget(
            name: "Hwalja",
            dependencies: ["HwaljaKit"],
            path: "App/Main",
            // Info.plist in the binary too, so a run without the bundle (Xcode, swift run) still has its document types.
            linkerSettings: [.unsafeFlags(["-L\(root)/build", "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Config/Info.plist"])]
        ),
        // Quick Look preview extension; shares the app's engine and page drawing (Preview/Editing).
        .executableTarget(
            name: "HwaljaPreview",
            dependencies: ["CHwpEngine", "SwiftMath"],
            path: "Preview",
            linkerSettings: [.unsafeFlags(["-L\(root)/build", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(
            name: "HwaljaTests",
            dependencies: ["HwaljaKit"],
            path: "Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
