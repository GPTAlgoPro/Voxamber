# GoogleThreeLiveNative

Small adapter around the genuine Google Three-Live Swift SDK, exact1.2.3. The local `ThreeLiveNative` dependency is used only for its metadata compatibility function; its Swift mesh exporter does not replace the Google compiler. This package has no language model, SceneSpec, template, WebView or generation fallback.

```swift
let engine = GoogleThreeLiveEngine()
let result = try await engine.compile(source: originalSceneCode)
// Persist result.source and hashes with the same immutable GLB/USDZ revision.
await engine.cancelAndWait()
```

Source is a Swift String, so external bytes must first be decoded as strict UTF8. The adapter passes its unmodified UTF8, rejects empty/embeddedNUL/over1MiB source, and does not strip fences, normalize text or repair code.

The pipeline executes source once with official `ThreeCompiler.compileGLB`, transcodes those exact GLB bytes using official `glbToUSDZ`, then applies the separately tested single-USDA metadata compatibility layer. It never executes the source again to produce USDZ. Original source, exact output bytes, hashes and pinned SDK identity are returned. Imported code remains subject to the official supported API and native execution/resource limits; successful compilation alone is not visual acceptance.

One operation is admitted per adapter instance; overlaps throw `busy`. Upstream additionally serializes calls on its persistent8MiB native compiler thread. Cancellation signals the owned worker and awaits native settlement. Running/queued official calls are not interruptible. Cancellation prevents subsequent stages/result publication once the current call returns. `cancelAndWait` joins the captured operation; an old completion cannot clear or cancel a newer operation. There is deliberately no `unload` alias or claim that the official VM has been destroyed.

Native diagnostics propagate unchanged when the caller has not cancelled. Actual compiler execution and packaging may fail or exceed expected timings. The250ms script and1000ms packaging checks in the pinned SDK are not an adapter-level hard deadline or whole-process memory guarantee.

Version/revision/checksum constants identify the pinned dependency. The SDK exposes no runtime ABI version query. The build owner must verify `Package.resolved` resolves1.2.3 to `c0ff24b628795286a175f1a71611673df5dbc05d` and the official XCFramework checksum matches before accepting a build. This source preparation does not download, build or embed the dependency. Tests using the internal scripted-operation seam check adapter ordering and ownership only; they are not proof of official compiler/device/format or visual success.
