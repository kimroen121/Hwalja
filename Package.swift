// swift-tools-version: 6.0
import PackageDescription

// CLT compile route. Bundle metadata, sandboxing and hosted tests require Xcode.
let package = Package(
    name: "HwpStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HwpStudio", targets: ["HwpStudio"])],
    targets: [.executableTarget(name: "HwpStudio", path: "App")]
)
