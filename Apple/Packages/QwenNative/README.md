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

Production generation uses the single-turn raw-token path, with a fresh cache and no ChatSession/history/tools layer. Direct-answer decoding uses a bounded 8192-token KV cache, prefill chunks of 128 and a default/hard maximum of 3072 output tokens. JSON completion and a 16 KB response cap are checked before return; CreationCore separately enforces the exact schema, duplicate keys, finite numbers and geometry budgets. Cancellation cancels and awaits the native producer before release. `thinking:true` is explicitly unsupported. Call `unload()` when backgrounding and after memory warnings.

Graph trace/fusion compilation is disabled through the official `MLX.compile(enable: false)` API; Metal operators remain native. Three real load→generate→unload cycles retained about 4/8/12 KB after release, versus hundreds of MB growing each cycle with the compiled Qwen3.5 path. `session.clear()` and trace invalidation alone did not resolve that growth. This evidence is from the measured Mac, not a phone performance guarantee.

`generateJSONDirect` is the shared raw implementation and also a diagnostic API. It uses the official `TokenIterator` plus `generateTokenTask` raw stream. It supports `maxTokens: 8` and `prefillStepSize: 64` or `128`; its return may be a partial diagnostic response. Stage callbacks log only phase, elapsed time and token counts, and progress text is blank. `generateJSON` wraps this path with complete JSON validation; Direct owns the sole task lifecycle. `memorySnapshot()` is nonisolated so allocator sampling does not queue behind actor-bound prefill.

On the measured iPhone, the direct tiny case reached its first token at 0.742 s and the full 1031-token ScenePrompt at 1.896 s. The old interaction path timed out before visible output in the device probe. This establishes a working replacement path; it does not identify the exact SDK statement behind the old timeout or establish a general A19 kernel defect. The formal wrapper also passed a Mac full ScenePlan→mesh→GLB/USDZ regression and a second same-engine JSON call without `Busy`.

Versions are fixed in Package.swift and the full dependency tree is in Package.resolved. See `Licenses/` for native library and original Qwen weight notices. The MLX Community conversion is separately pinned by its complete public snapshot revision and individual file hashes in `Apple/Resources/ModelCatalog.json`, with a byte-identical pinned ModelScope mirror.

The Qwen3.5 4B original has 4,659,865,088 total stored parameters (including vision), within the user's 8B ceiling. A text-only load retains about 2.37 GB of quantized MLX weights on the measured Mac. This is not an iPhone memory guarantee or a claim that the current model's general 3D planning quality has passed acceptance.

`QwenBench` is a Mac development executable, not a dependency of the QwenNative library product or app. It measures Chinese parameter interpretation plus real model-generated chair/robot/lamp SceneSpec→meshes→GLB/USDZ, including spatial diagnostics and at most one feedback generation. Its report differentiates schema validity, requested properties, physical relations, timing and memory. Native mesh validity is not a claim of visual acceptance.

```sh
swift build -c release --package-path Apple/Packages/QwenNative
Apple/Packages/QwenNative/.build/release/QwenBench \
  Apple/.build/Models/qwen3.5-4b-mlx-int4 \
  docs/qa/qwen4b-macos-benchmark.json
```

The Mac needs Apple's Metal compiler component (`xcodebuild -downloadComponent MetalToolchain`). No development helper or Python interpreter belongs in the app bundle.
