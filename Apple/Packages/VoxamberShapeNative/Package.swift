// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"VoxamberShapeNative",platforms:[.iOS(.v26),.macOS(.v14)],products:[
    .library(name:"VoxamberShapeNative",targets:["VoxamberShapeNative"])
],dependencies:[.package(url:"https://github.com/ml-explore/mlx-swift",exact:"0.32.3")],targets:[
    .target(name:"VoxamberHy3D",dependencies:[
        .product(name:"MLX",package:"mlx-swift"),.product(name:"MLXNN",package:"mlx-swift"),
        .product(name:"MLXRandom",package:"mlx-swift"),.product(name:"MLXFast",package:"mlx-swift")]),
    .target(name:"VoxamberShapeNative",dependencies:["VoxamberHy3D",.product(name:"MLX",package:"mlx-swift")],
        resources:[.copy("Resources/Legal"),.copy("Resources/hunyuan-shape-2.1.yaml")]),
    .testTarget(name:"VoxamberShapeNativeTests",dependencies:["VoxamberShapeNative","VoxamberHy3D"])
])
