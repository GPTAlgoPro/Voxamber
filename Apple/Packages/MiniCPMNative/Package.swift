// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiniCPMNative",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [.library(name: "MiniCPMNative", targets: ["MiniCPMNative"]),
               .executable(name: "MiniCPMBench", targets: ["MiniCPMBench"])],
    dependencies: [.package(path: "../CreationCore")],
    targets: [
        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
        .target(name: "CMiniCPM", dependencies: ["llama"], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate"),
                                 .linkedFramework("Metal"), .linkedFramework("Foundation")]),
        .target(name: "MiniCPMNative", dependencies: ["CMiniCPM"]),
        .executableTarget(name: "MiniCPMBench", dependencies: ["MiniCPMNative", "CreationCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
