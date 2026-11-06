# Public NativeCreationEngine full lamp gate — armed only

This is one fresh call to the actual current production public `NativeCreationEngine.generate`. It must run the engine's own Qwen→CoreML SDXL→Vision preparation→MLX Shape→native GLB/USDZ sequence. The runner does not call individual model stages, use a pre-existing vase/reference image, substitute a preset/currentSpec/manual mesh, alter prompts/weights/sampling/options, or retry a failed stage. No model download, phone operation, App source change or Apple distribution action is part of this gate. It remains armed until parent GO.

Fixed original LP request, byte-for-byte:

> 做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。

Requested seed24301. Actual current production parameters are taken from source, not overridden by the runner:

- Intent: pinned existing Qwen3.5-0.8B MLX INT4; real formal `generateJSON`, greedy/no thinking, exact current CreationIntentDecoder system/schema, maximum512 output tokens, positive English ASCII1–512characters, no other model output field; title derives from source prompt, negative is empty. Character count and token cap are distinct. No manual translation or repair.
- Image: pinned Apple compiled SDXL,768²,20steps,DPM Solver Multistep,guidance7.5,reduceMemory=true,cpuAndNeuralEngine, actual seed UInt32(24301). The actual public ImageEngine method is used through the public creation pipeline; there is no extra warm-up/image request or altered dimensions.
- Preparation: the pipeline's actual Apple Vision all-foreground request and transparent512RGBA framing. No synthetic mask, opaque/whole-frame fallback or second Vision call.
- Shape: distinct verified rebuilt candidate30b93ce8…,MLX0.32.3,4096latents,10steps,guidance5,octree192,serialized CFG,MoE512-token chunks,cache64MiB,seed24301,finite-positive-f64-v1. iOS5.5GiB admission remains unchanged. Host Mac observations cannot establish12GB iPhone/6GiB whole-App acceptance.

All39 existing runtime resource files (Qwen10+SDXL27+Shape2) must match their exact bundled manifest byte counts and SHA256 before GO. Their total is6188648194bytes. Runtime constructor layout checks alone are not checksum proof. The SDK additionally verifies the selected whole Shape pack before load. Qwen model-card Base/non-Base provenance uncertainty is retained; actual English fidelity must be read rather than inferred from the model name.

## Public observation boundary and ownership

Progress events and independent OS physical-footprint samples are saved during execution, nominal interval200ms. Every phase transition flushes event/memory files and an atomic current-stage readback. Samples and observed maxima are measurements, not guarantees that every transient peak is captured. Callback file I/O adds observation overhead; timing is not a controlled performance comparison.

`onReferenceImage` immediately persists that actual returned768PNG before Vision. The public API exposes decoded intent/prepared512 only in a successful `NativeCreationResult`. On success save them, exact returned reference, real shape buffers' artifacts/base/provenance/statistics/validation receipt and actual per-phase times. On failure retain only publicly observed reference/progress/memory/error. Do not fabricate unavailable intent/prepared data or rerun any stage to retrieve it. Raw Qwen response, per-token telemetry and independent image-stage runtime provenance are not exposed by this API; pinned source/resource configuration must be labeled configuration evidence, not invented runtime callbacks.

The sole generation Task is owned and cancelled by the900s QA watchdog or telemetry I/O failure. After cancellation, await actual completion and `engine.cancel()/unload()` before final status/exit. This is cooperative: a synchronous CoreML prediction or long Shape forward may settle after900s. Record whether the watchdog fired and actual duration; never claim hard preemption or a verified phone stop bound. Never retry. Unload must leave `engine.isRunning == false` for success. Final cleanup cancelling an already completed Task is separate from an operation cancellation.

## Acceptance rubric fixed before outputs

Keep operational completion, language semantics, image/Vision fidelity, native format integrity and visual modeling quality separate. A JSON or file success is not a full product pass.

1. Read actual returned English intent: one desk lamp, red conical shade, gray cylindrical base, thin cylindrical stem, grounded/Y0 intent and approximately0.8m height retained. Optional spherical bulb may be present or absent. No floor-lamp/object substitution or invented mandatory articulation/objects. Ground wording may express Y0; no unrequested texture requirement.
2. View actual768 reference: identifiable complete single lamp; red conical/conical-frustum shade, gray round cylindrical/disk base, thin rod; no unrequested structure that changes the request. A background is not itself a failure because this fixed prompt did not request a white studio.
3. View actual512alpha preparation: main lamp including thin stem/base/shade preserved, coherent foreground isolation, no full-frame substitute or lost requested part. Vision success alone is not segmentation-fidelity acceptance.
4. Inspect actual exported GLB/USDZ and two-view renders: recognizable coherent lamp, shade/base/stem present and connected, proportions plausible, no prominent floating fragments, torn surfaces or missing thin rod. Native counts/bounds/finite indices, actual topology, artifact hashes and native import are recorded. No geometry repair, smoothing, decimation or renderer-only replacement may be applied.
5. Final Shape is currently untextured gray. It cannot be credited with reproducing red/gray part colors or learned textures. Source PNG colors and any later CPU projection experiment do not count as output texture generation for this public API.
6. Text saying0.8m is not a measured mesh height; source model geometry is normalized and physicalScaleKnown=false. Do not relabel normalized units as surveyed metres. Record actual bounds; Y0/0.8m geometry/scale is unverified unless the actual pipeline explicitly establishes it (currently it does not rescale/ground the mesh). This remains a product limitation, not a post-hoc tolerated metric pass.

Only one known LP fixture/seed is tested; no all-topic reliability or phone performance claim follows. Full general modeling/visual quality remains subject to actual image/mesh review.

Pending command (refuses existing output):

```
Apple/.build/NativeCreationLampGateBuild/out/Products/Release/NativeCreationLampGate Apple/.build/NativeCreationLampGate/LampPublic01
```
