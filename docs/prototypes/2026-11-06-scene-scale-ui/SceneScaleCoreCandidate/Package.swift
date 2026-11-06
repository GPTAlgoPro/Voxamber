// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CreationCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "CreationCore", targets: ["CreationCore"])],
    targets: [
        .target(name: "CreationCore"),
        .testTarget(name: "CreationCoreTests", dependencies: ["CreationCore"])
    ]
)
