# VoxamberShapeNative

Native Swift/MLX image-to-shape SDK, derived from the pinned Snap3D Hunyuan3D mobile runtime. It embeds code/config/licenses, **no weights or Python/JavaScript runtime**. MLX is pinned to0.32.3 to coexist with QwenNative. Building this adaptation does not prove numerical or geometry parity with the historically measured0.31.4 runtime.

```swift
let engine = ShapeEngine()
let result = try await engine.generate(
    pngData: prepared512ForegroundAlphaPNG,
    shapePackURL: verifiedLocalPackURL,
    configurationYAML: try HunyuanShape21Configuration.bundledYAML,
    seed: 24301)
// Real buffers and artifacts; not a SceneSpec or a preset.
let buffers = result.mesh
let glb = result.glbData
let usdz = result.usdzData
let originalGeometry = try ShapeMeshArchive.read(data: result.baseMeshData)
await engine.unload()
```

Input must be a decoded512² PNG preserving the foreground alpha. The original preprocessor takes the alpha>0.5 bounding box, recenters with border0.15 and composites white internally before DINO. White display composition must not erase that alpha. Opaque PNGs decode but carry no foreground-mask bbox and are not equivalent preprocessing. The SDK does not run a new segmentation model. CoreML image generation, foreground preparation and this shape stage must execute serially; await the previous stage's actual resource unload before calling Shape.

The accepted pack is exactly2,490,378,616bytes, SHA25669cd908e83bbf51200c63a2a163e2dfd34d2be0571c33b92f4a922489c564842. It is a prepacked mixedQ4/FP16 model; the SDK never quantizes a full FP16 tree on a phone. Configuration is hash-pinned. The public mobile profile retains4096latents,10steps,octree192,serialized CFG and dense MoE512-token chunks. It does not shorten the trained latent geometry to manufacture a memory result.

Task cancellation directly sets the real worker's cooperative token, cancels the worker Task and awaits it. `cancel()` requests the same stop; `unload()` cancels/awaits active work and does not create a cold Metal device when idle. Status derives from the actual token/owner state. A process-wide Shape lease prevents two SDK instances loading shape together. The caller still owns global serialization against Qwen/CoreML/other engines.

Cancellation is polled at existing stage/denoise/SDF/meshing boundaries. A long DiT forward is not force-preemptible; a few-second single2.1 iPhone stop bound has **not** been verified. The historical phone shape pass took281.93s in a Release development test host with initial5.92GiB process headroom. The often-quoted4.43GiB peak is a separate Mac measurement. Current whole-App6GiB peak, repeated/thermal/cancel behavior and0.32.3 model parity require real inference evidence.

`ShapeMeshArchive` uses standard geometry GLB2: formatID`org.khronos.gltf.binary`, version2, geometryLayoutVersion1. It stores the generated positions/UInt32 indices; normals are deterministically derived from that geometry on restore. It does not promise preservation of arbitrary editor-authored normals. `ShapeResult.baseMeshData` is the unchanged generated GLB and may share the same hash/blob as its export role. The SDK's reader accepts its flattened source geometry layout, not arbitrary external scene hierarchies.

Explicit output limits:2,000,000vertices;4,000,000triangles/12,000,000indices;256MiB GLB;512MiB USDZ. Excess is rejected, never silently decimated. This is independent of the old SceneSpec1024-vertex budget and old exporter100k/300k-index cap. Nine no-weight SDK tests include a154,449vertex/307,328triangle synthetic CPU export/restore; that fixture is not neural generation evidence.

`validationReceipt` reports actual counts/bytes/hashes and native artifact checks from the real backend boundary; it is not a signature, visual acceptance, metric-accuracy claim or numerical-parity certificate. `physicalScaleKnown` remains false: the learned model's normalized geometry is not surveyed metres. CPU artifact serialization retains all finite source Float values.

Source/config/parameter/device-evidence provenance lives in `docs/prototypes/2026-11-06-native-neural-pipeline/shape-backend/`. Swift-port MIT, source third-party notices and the full pinned Tencent2.1 license/notice are retained under Resources/Legal. Model-license obligations and territory restrictions remain separate from the SDK code license.

Real neural generation is explicitly rejected on Simulator before model loading. Simulator may exercise CPU I/O and geometry exports, not MLX shape inference.

## CPU mesh edits and persistent exports

`ShapeMeshEditor.export(base:recipe:baseArchiveData:isCancelled:)` synchronously produces a new mesh and real GLB/USDZ. Run it on an owned background task; cancel that task and await it. It never loads weights. Pass the immutable original base buffers and original layout1 GLB as `baseArchiveData`; the SDK verifies positions/indices/derived-normal equality and binds that exact base hash. Arbitrary normals not restorable from layout1 are rejected. Recipes are absolute from that base, not cumulative mutation of previous render buffers.

`ShapeEditRecipe` has version1, Double `translationXYZ`, `rotationXYZdegrees`, `positiveScaleXYZ`, and optional `wholeMaterial`. Positions apply scale→X rotation→Y rotation→Z rotation→translation. Normals apply the inverse transpose and normalize. Positive scale preserves index winding; indices/counts/topology remain unchanged. Nonfinite/invalid values, nonpositive scale, degenerate base faces, output coordinates/extents above1,000,000model units, Float32 triangle collapse or reversal are explicitly rejected. Planar meshes remain supported. These are export/precision bounds, not a claim of surveyed metre accuracy.

Whole-material RGBA is linear Rec.709/sRGB, plus metallic/roughness0...1. GLB writes standard PBR factors and actual NORMAL accessor2 after indices0/POSITION1. USDZ writes bound UsdPreviewSurface, declared linearP3-D65 color converted from Rec.709, scalar opacity/metallic/roughness, and the actual transformed normals/points. A native Apple importer readback verifies converted-back Rec.709 color and PBR/opacity, beyond checking text presence. No viewport-only material change or texture-generation claim is used.

Default generation still produces unchanged layout1 base geometry and default USDZ when optional export parameters are nil. Edited render GLB is layout2 (three accessors/views), while the immutable original base remains layout1. Keep its original neural generation evidence; the independent CPU `ShapeEditValidationReceipt` has `actualNeuralWeightsUsed:false` and must never replace it or be counted as another AI generation. The result includes new artifact hashes, bounds, counts and base/recipe identities.
