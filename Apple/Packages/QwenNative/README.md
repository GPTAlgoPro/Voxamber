# QwenNative

Native Swift MLX/Metal inference for local model files. The library does not download files, launch a server, interpret scripts, or use remote inference. The app's verified resource store owns downloads and SHA-256 checks.

```swift
let engine = QwenEngine()
try await engine.load(modelDirectory: modelDirectory)
let json = try await engine.generateJSON(
    systemPrompt: ScenePrompt.system,
    prompt: try ScenePrompt.userRequest(description),
    maxTokens: 1536
) { progress in
    // Send progress to the main actor if updating UI.
}
let scene = try SceneSpec.decodeModelResponse(json)
await engine.unload()
```

Each generation has an independent ChatSession. Greedy direct-answer decoding uses a bounded 8192-token KV cache; the output default is 1536 tokens and hard maximum is 3072. JSON completion is checked before return, and CreationCore separately enforces the exact schema, duplicate keys, finite numbers and geometry budgets. Cancellation propagates into MLX prefill/generation. Call `unload()` when backgrounding and after memory warnings.

Versions are fixed in Package.swift and the full dependency tree is in Package.resolved. See `Licenses/` for native library and original Qwen weight notices. The MLX Community conversion is separately pinned by its complete public snapshot revision and individual file hashes in `Apple/Resources/ModelCatalog.json`, with a byte-identical pinned ModelScope mirror.

The Qwen3.5 4B original has 4,659,865,088 total stored parameters (including vision), within the user's 8B ceiling. A text-only load retains about 2.37 GB of quantized MLX weights on the measured Mac. This is not an iPhone memory guarantee.

`QwenBench` is a Mac development executable, not a dependency of the QwenNative library product or app. It measures Chinese parameter interpretation plus real model-generated chair/robot/lamp SceneSpec→meshes→GLB/USDZ, including spatial diagnostics and at most one feedback generation. Its report differentiates schema validity, requested properties, physical relations, timing and memory. Native mesh validity is not a claim of visual acceptance.

```sh
swift build -c release --package-path Apple/Packages/QwenNative
Apple/Packages/QwenNative/.build/release/QwenBench \
  Apple/.build/Models/qwen3.5-4b-mlx-int4 \
  docs/qa/qwen4b-macos-benchmark.json
```

The Mac needs Apple's Metal compiler component (`xcodebuild -downloadComponent MetalToolchain`). No development helper or Python interpreter belongs in the app bundle.
