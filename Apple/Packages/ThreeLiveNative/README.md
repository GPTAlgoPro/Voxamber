# ThreeLiveNative

This package is not Google's ThreeLiveCompiler. The existing geometry serializer
is retained for existing projects. `OfficialUSDZCompatibility.repair(_:)` is a
separate, pure-Swift metadata repair for the pinned Google v1.2.3 compiler's
single-`model.usda`, stored-ZIP USDZ output. It adds explicit
`MaterialBindingAPI` and `subdivisionScheme = "none"` without changing geometry
or material values. It validates archive boundaries and CRC, rejects unsupported
layouts, and returns an already repaired archive byte-for-byte. It does not run
scene code or stand in for the official compiler.

```swift
let appleCompatibleUSDZ = try OfficialUSDZCompatibility.repair(rawOfficialUSDZ)
```

Pure Swift geometry export for the native app. It serializes validated
CreationCore.GeneratedMesh arrays to glTF 2.0 GLB and Apple USDZ using Foundation.
The module contains no Python, JavaScript, Rust/Boa interpreter, WebView,
remote service, or binary dependency.

```swift
import CreationCore
import ThreeLiveNative
let meshes = try SceneGenerator.generate(for: spec)
let glb = try ThreeLiveNative.exportGLB(meshes)
let usdz = try ThreeLiveNative.exportUSDZ(meshes)
```

Call these synchronous CPU operations away from the main actor. Each mesh is a
cancellation checkpoint. Export never mutates the source data. The caller owns
atomic publication and discards stale generation results.

Coordinates are Y-up and measured in meters. GLB uses float32 positions/normals,
uint32 triangle indices and one PBR material per mesh. USDZ uses a stored ZIP
with 64-byte aligned payload, a valid CRC32, explicit MaterialBindingAPI, and
subdivisionScheme=none. It contains USDA and requires no USDC conversion.

Input validation rejects malformed arrays, invalid indices/non-finite values,
invalid materials, and totals above 1,000 meshes/100,000 vertices/300,000 indices.
Output uses stable ordering and contains no timestamps or random identifiers.

Verification: `swift test --package-path Apple/Packages/ThreeLiveNative`.
Tests validate real CreationCore models, binary layout and both format contracts.
External Khronos/Apple validators and RealityKit loading provide independent
format/runtime acceptance; simulator or Mac checks do not prove iPhone speed.
