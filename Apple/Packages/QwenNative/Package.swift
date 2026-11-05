// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QwenNative",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "QwenNative", targets: ["QwenNative"]),
        .executable(name: "QwenBench", targets: ["QwenBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"),
        .package(path: "../CreationCore"),
        .package(path: "../ThreeLiveNative"),
    ],
    targets: [
        .target(name: "QwenNative", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .executableTarget(name: "QwenBench", dependencies: ["QwenNative", "CreationCore", "ThreeLiveNative",
            .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm")],
            resources: [.copy("plan-schema.json")]),
        .testTarget(name: "QwenNativeTests", dependencies: ["QwenNative", "CreationCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm")]),
    ]
)
