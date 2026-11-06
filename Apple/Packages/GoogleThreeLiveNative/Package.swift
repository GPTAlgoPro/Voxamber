// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoogleThreeLiveNative",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "GoogleThreeLiveNative", targets: ["GoogleThreeLiveNative"])],
    dependencies: [
        .package(url: "https://github.com/google/three-live", exact: "1.2.3"),
        .package(path: "../ThreeLiveNative")
    ],
    targets: [
        .target(name: "GoogleThreeLiveNative", dependencies: [
            .product(name: "ThreeLiveCompiler", package: "three-live"), "ThreeLiveNative"
        ]),
        .testTarget(name: "GoogleThreeLiveNativeTests", dependencies: ["GoogleThreeLiveNative"])
    ]
)
