// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxamberFluxCandidate", platforms: [.macOS(.v14), .iOS(.v26)],
    products: [.library(name: "VoxamberFluxCandidate", targets: ["VoxamberFluxCandidate"]),
               .executable(name: "FluxCandidatePreflight", targets: ["FluxCandidatePreflight"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ], targets: [
        .target(name: "MLXProfiler", dependencies: [.product(name: "MLX", package: "mlx-swift")]),
        .target(name: "FluxTextEncoders", dependencies: ["MLXProfiler", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"), .product(name: "MLXRandom", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift"), .product(name: "Transformers", package: "swift-transformers")]),
        .target(name: "Flux2Core", dependencies: ["FluxTextEncoders", "MLXProfiler", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"), .product(name: "MLXRandom", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift"), .product(name: "Transformers", package: "swift-transformers")], exclude: ["Training"]),
        .target(name: "FluxCandidateResources", resources: [.copy("flux2-manifest.json")]),
        .executableTarget(name: "FluxCandidatePreflight", dependencies: ["FluxCandidateResources"]),
        .target(name: "VoxamberFluxCandidate", dependencies: ["FluxCandidateResources", "Flux2Core", "FluxTextEncoders", .product(name: "MLX", package: "mlx-swift")]),
        .testTarget(name: "FluxCandidateTests", dependencies: ["VoxamberFluxCandidate", "FluxCandidateResources", "Flux2Core", "FluxTextEncoders", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift")])
    ])
