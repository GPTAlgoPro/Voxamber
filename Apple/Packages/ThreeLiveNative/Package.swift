// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThreeLiveNative",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "ThreeLiveNative", targets: ["ThreeLiveNative"])],
    dependencies: [.package(path: "../CreationCore")],
    targets: [
        .target(name: "ThreeLiveNative", dependencies: ["CreationCore"]),
        .testTarget(name: "ThreeLiveNativeTests", dependencies: ["ThreeLiveNative"])
    ]
)
