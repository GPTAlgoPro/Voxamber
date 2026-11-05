# One neural raw mesh, two CPU cleanup policies (armed, not yet run)

Purpose: test whether mesh cleanup causes open boundaries by comparing two deterministic CPU policies on **the exact same captured pre-cleanup neural mesh**. This is not a second model, precision/runtime comparison, prompt retry, repair of the previous accepted artifact, or automatic quality acceptance. Earlier vase exports remain unchanged.

One fresh NN call is allowed only after parent GO. Fixed input `docs/qa/2026-11-06-native-image-vase/reference-prepared-512-rgba.png`,249722bytes/SHA1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae. Same distinct Q4 candidate30b93ce8…(2490378518bytes), currentMLX0.32.3,4096latents,10steps,guidance5,seed24301,octree192,serializedCFG,MoE512-token chunks,cache64MiB. No prompt, weights, runtime, resolution or sampler change; no retry/fallback. The iOS5.5GiB admission constant is unchanged; this host run cannot pass a phone memory gate.

Entry is the **lower-level VoxamberHy3D.ShapeGenerator.generateGLB** with the newly optional `onRawMesh` value callback, not `ShapeEngine.generate`. The host wrapper copies production config/YAML/input validation, selected profile preflight+whole-file SHA, global Shape runtime lease, owned worker+cooperative cancellation, awaited600s watchdog, stream synchronize and cache clear. It retains the lease through CPU export settlement. The public ShapeEngine API and App default remain unchanged. The callback defaults to nil, makes no implicit files, and ordinary production calls still use legacy cleanup.

The sole NN worker stores a raw GLB directly from the callback before cleanup and preserves the normal default-legacy GLB. The writer serializes that supplied vertex/index value; it does not apply cleanup. After the worker releases weights, the host verifies that reopening raw GLB yields the same vertices/indices. Both CPU variants then start from that same raw value:

- legacy: existing Float32 squared-double-area threshold1e-16 and original compaction;
- strict diagnostic: finite/distinct/index-valid faces with a nonzero Float64 cross vector, no epsilon. It avoids Float32 squared-area underflow but is a Double numeric predicate, not an adaptive exact predicate for every possible extreme coordinate dynamic range.

This is a cleanup-policy bundle comparison (threshold **and** predicate precision), so the host additionally classifies raw faces into positive-Float32-under-threshold, Float32-square-underflow, Float32-cross-zero/Double-positive, or other cases. No face is fabricated, welded, filled, smoothed, reoriented, simplified or replaced. Strict retains only original raw faces; nothing is patched into the previous mesh.

For each CPU variant preserve real GLB/USDZ, vertex/face counts, bounds, hashes and native SceneKit USDZ triangle/line/other primitive counts. Derived legacy must be compared to the default export from the same NN call. Run the same CPU topology diagnostic on raw/legacy/strict: degenerate/repeated/nonfinite faces, unique edges, boundary loops, nonmanifold edges/vertex links, components and Euler/genus where valid. Record any artifact/import failure. Boundary reduction alone is insufficient: compare actual two-view renders and remaining wrinkles/holes/islands; do not claim CAD quality, quantization attribution, phone performance or production actor/cancellation validation.

Capture source/binary/bundles/input hashes before and after. The600s watchdog requests cancellation then awaits actual settlement; it is not a hard preemption bound. This host diagnostic retains raw data and writes extra files, so its observed time/memory cannot be treated as an equivalent ordinary-App benchmark.

Exact pending command (refuses an existing destination):

```
Apple/.build/NativeShapeCleanupGate/NativeShapeCleanupGate docs/qa/2026-11-06-native-image-vase/reference-prepared-512-rgba.png Apple/.build/NeuralModels/Shape21Q4/model.q4.safetensors Apple/.build/NativeShapeCleanupGate/VaseSingleRaw01
```
