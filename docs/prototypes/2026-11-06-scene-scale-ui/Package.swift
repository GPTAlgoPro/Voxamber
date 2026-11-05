// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SceneScaleUIPrototype",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "SceneScaleUIPrototype", targets: ["SceneScaleUIPrototype"])],
    dependencies: [.package(path: "SceneScaleCoreCandidate")],
    targets: [
        .target(name: "SceneScaleUIPrototype", dependencies: [
            .product(name: "CreationCore", package: "SceneScaleCoreCandidate")
        ]),
        .testTarget(name: "SceneScaleUIPrototypeTests", dependencies: ["SceneScaleUIPrototype"])
    ]
)
