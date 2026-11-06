// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxamberImageNative",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "VoxamberImageNative", targets: ["VoxamberImageNative"])],
    targets: [
        // Upstream Apple sources use their original Swift 5 concurrency model.
        .target(name: "AppleSDXL", path: "Sources/AppleSDXL", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "VoxamberImageNative", dependencies: ["AppleSDXL"], path: "Sources/VoxamberImageNative"),
        .testTarget(name: "VoxamberImageNativeTests", dependencies: ["VoxamberImageNative", "AppleSDXL"],
                    path: "Tests/VoxamberImageNativeTests", resources: [.copy("Fixtures")])
    ]
)
