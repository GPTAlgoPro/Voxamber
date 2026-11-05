// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SceneMeasurementKernel",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "SceneMeasurementKernel", targets: ["SceneMeasurementKernel"])],
    dependencies: [.package(path: "../../../Apple/Packages/CreationCore")],
    targets: [
        .target(name: "SceneMeasurementKernel", dependencies: [
            .product(name: "CreationCore", package: "CreationCore")
        ]),
        .testTarget(name: "SceneMeasurementKernelTests", dependencies: ["SceneMeasurementKernel"])
    ]
)
