// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ReferenceColorProjection", platforms: [.macOS(.v14)],
    products: [.executable(name: "reference-color-projection", targets: ["ReferenceColorProjection"])],
    targets: [.executableTarget(name: "ReferenceColorProjection"),
              .testTarget(name: "ReferenceColorProjectionTests", dependencies: ["ReferenceColorProjection"])])
