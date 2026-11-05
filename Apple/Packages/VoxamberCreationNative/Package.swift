// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxamberCreationNative",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [.library(name: "VoxamberCreationNative", targets: ["VoxamberCreationNative"])],
    dependencies: [
        .package(path: "../QwenNative"),
        .package(path: "../CreationCore"),
        .package(path: "../VoxamberImageNative"),
        .package(path: "../VoxamberShapeNative")
    ],
    targets: [
        .target(name: "VoxamberCreationNative", dependencies: [
            "QwenNative", "CreationCore", "VoxamberImageNative", "VoxamberShapeNative"
        ]),
        .testTarget(name: "VoxamberCreationNativeTests", dependencies: ["VoxamberCreationNative"])
    ]
)
