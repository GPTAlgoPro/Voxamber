# Single native Shape candidate gate (predeclared)

One actual Shape API call on the host Mac (48GiB RAM), using the previously generated/prepared vase PNG exactly as saved. This is not an iPhone inference, App integration, or new text-to-image run. No retry, fallback, preset, reduced geometry profile, parameter change, or output repair is allowed. Failures and timeout status are retained.

Input: `docs/qa/2026-11-06-native-image-vase/reference-prepared-512-rgba.png`, 512² foreground-alpha PNG, 249722bytes, SHA256 `1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae`.

Model: distinct candidate `native-rebuild-20261106-q4-30b93ce8`, 2490378518bytes/SHA256 `30b93ce8a801551b905c35d1203d71d947a6b35b3d271aa5820b11d40faf45c7`; source/recipe verification is separately sealed under `docs/prototypes/2026-11-06-native-neural-pipeline/shape-backend/rebuild-parity`. It is not asserted tensor-identical to unavailable legacy69. The SDK verifies the whole selected pack SHA before loading.

Runtime: current unmodified neural math under MLX0.32.3. Explicit `ShapeEngine(weightProfile: .rebuiltQ4Candidate)`, trained4096latents,10steps, guidance5, octree192, serialized CFG, constrained MoE512-token chunks, cache64MiB, seed24301. The iOS admission threshold remains5.5GiB available process memory; a host run does not satisfy that phone gate. Expected host headroom is conservatively8–10GiB given historical separate4.43GiB MLX peak plus process/input/output overhead; actual current footprint/MLX peak must be recorded rather than inferred.

The QA watchdog requests cancellation after600s, then the caller awaits actual generation/cleanup settlement. Its triggered flag is recorded. This is cooperative cancellation, not a claim of hard interruption at600s or a verified phone stop bound. Independent OS task footprint samples run at nominal100ms; their observed maximum is not a guarantee that every transient physical peak was sampled.

Record actual progress/stage times, call status, statistics, provenance, validation receipt, GLB/USDZ/base bytes and hashes, sampler count/physical observations, and after-unload footprint. SDK artifact success requires actual nonempty finite/index-valid native geometry and real format export; no schema-only or toy-substitution acceptance. Exported status remains pending visual review. Visual review must inspect the actual mesh/ silhouette/shape, not merely the source PNG or counters. No physical-scale or texture/material-generation acceptance is claimed.

Executable command (one process/call; refuse an existing output directory):

```
Apple/.build/NativeShapeGate/NativeShapeGate docs/qa/2026-11-06-native-image-vase/reference-prepared-512-rgba.png Apple/.build/NeuralModels/Shape21Q4/model.q4.safetensors Apple/.build/NativeShapeGate/VaseCandidate30b93
```
