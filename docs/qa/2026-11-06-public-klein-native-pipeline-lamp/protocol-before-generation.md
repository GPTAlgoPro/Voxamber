# Full public Klein LP pipeline — declared before inference

Preparation only. This condition must wait for Root's explicit GO before `--run`. Building and `--prepare` perform no Qwen, Flux, Vision, Shape, Metal rendering or model evaluation. App defaults, active SDXL manifest/delivery, all packs, phone and TestFlight remain unchanged.

The one fixed original Chinese request is:

> 做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。

Requested seed is UInt64(24301). This small fixed seed does not experimentally distinguish high-bit truncation; the package's separate high-UInt64 receipt tests and inspected direct seed call are the evidence for that API contract. The actual image-stage receipt must equal the selected `.klein4B.receipt(requestedSeed:)` and is saved independently.

## One actual call, fresh stages

The sole NN entry is `NativeCreationEngine.generate(prompt:seed:resources:onProgress:onReferenceImage:)`, explicitly using `CreationResources(..., imageBackend: .klein4B)`. The Host does not call the component engines to retry, supplement or repair this result. It does not read a previous intent, prepared mask, reference image, mesh or rendered output.

1. Fresh pinned Qwen3.5-0.8B INT4 translation through the current native creation decoder's exact source system/schema. Printable ASCII positive-only max512; native title and empty negative. Generation max512 tokens with the current formal greedy/no-thinking implementation. No independently substituted English brief.
2. Fresh fixed Flux2 Klein4B affineQ4/group64 DiT plus Qwen3-4B affineQ4/group64 text encoder and full small VAE: 512×512,4steps,guidance1,full UInt64 seed,upsampling=false,conservative memory profile,TE unload before DiT+VAE,DiT unload before VAE decode. No negative CFG. The aggregate image component contains approximately7.96B parameters; it is not described as only a4B total pipeline.
3. The current public pipeline calls the actual Apple Vision all-foreground preparation once, output512RGBA. No synthetic mask, full-frame fallback, cable removal, manual crop, alpha modification or injected part.
4. The pipeline's public ShapeEngine uses verified30b93 rebuilt Q4,4096latents,10steps,guidance5,octree192,serializedCFG,MoEchunk512,cache64MiB,seed24301,finite-positive-f64-v1. No new cleanup policy, math, scheduler, pack, smoothing or parameter change.

The isolated workspace contains byte-identical snapshots of the current repository's seven SDK packages, with no source adaptations. Snapshot,Host,resource-bundle and executable identities are sealed before GO. SDK snapshots are independent of later Root edits; they are not silently refreshed.

## Exact resources and observability

Before either prepare or run, whole SHA256 and byte length are checked using bounded1MiB streaming reads for:

| Component | Files | Bytes |
| --- | ---: | ---: |
| Qwen0.8 intent | 10 | 645315928 |
| Flux image, all three subcomponents | 14 | 4704126845 |
| Shape30b93 | 1 | 2490378518 |

The25 exact file pins, independent source snapshot and shape YAML SHA are immutable files associated with the Host. The pipeline's Flux admission additionally verifies its exact fixed resources at actual load boundaries. Selected image backend/configuration/component revisions and expected image receipt are recorded at prepare; actual receipt comes only from a successful public result. Resources and SDK source hashes are rechecked after a run, including failed calls. A failed recheck fails the gate.

Public progress plus an independent nominal200ms task observe OS physical footprint and MLX active/cache/peak counters. No MLX counter is touched during prepare or cold preflight. In an explicit run, counters start only after the first actual public phase callback. The interpreting callback precedes actual intent-model loading; reading MLX counters may initialize backend bookkeeping then, and is not proof the model has loaded. SDKs may reset MLX peak counters; record this limitation and maximum actual sample gap. Samples can miss peaks. Phase`.complete` includes post-inference file/preview work; whole-Host memory can include native USDZ rendering and must not be relabeled as pure NN memory.

The actual reference callback is immediately written as512PNG and hashed. First actual returned intent/image-stage/prepared/GLB/USDZ/base/statistics/provenance are persisted before any contract guard rejects them, including mismatched metadata. Diagnostic persistence is not App publication or acceptance. A successful result must return the same bytes and exactly one reference callback. The Host reads alpha statistics from the actual prepared PNG, never changes it. Intent/prepared/result receipts are available only if the public call succeeds; on failure, preserve the actual error and public callback/progress artifacts without independently rerunning inaccessible stages.

## Ownership, cancellation and publication

One owned task contains the full public generation. A900s QA watchdog cancels that actual task, with sticky cancellation if owner assignment races, then awaits its result. This is a cooperative signal, not instantaneous GPU preemption or a guaranteed total timeout. Cancel and await the watchdog, await public creation engine cancel/unload, require `isRunning=false`, join the sampler and record cleanup observations. Every artifact/report I/O error fails the gate. No successful return is accepted after cancellation or telemetry failure.

No App project is published by this diagnostic. On success retain exact original reference, prepared image, GLB/USDZ/baseGLB, shape provenance/statistics/evidence, image receipt, helper intent and timings. The actual USDZ is imported for front/three-quarter images with camera/light/background changes only; no geometry/material substitutions. Rendering happens after successful cleanup and is outside the NN watchdog. No retry or reuse of an existing output directory.

## Acceptance remains split

The first fresh output is retained regardless of success. Check translation fidelity separately from image fidelity, segmentation, actual geometry structure, lifecycle and overall quality. Original requirements remain red conical/conical-frustum shade,gray cylindrical base,thin connected upright stem,optional spherical bulb,one lamp,grounded intent and approximately0.8m intent. Do not invent a new aesthetic or texture requirement.

Earlier staged LP gates showed a recognizable main structure but cable fragments and default gray untextured geometry. Those are not silently repaired or promoted to full-quality success. This condition has no texture/color-transfer implementation; gray geometry cannot prove requested3D red/gray colors. `physicalScaleKnown=false` remains truthful; an English0.8m request does not establish generated mesh meters. Inspect both actual views for contacts,holes,floaters,fragments,missing/extra structures and shade opening. Typed/file success and an identifiable silhouette alone are not full acceptance. This one Mac case proves neither arbitrary subject capability nor12GB iPhone memory/cancellation/performance, download, App preview/thumbnail/edit or TestFlight acceptance.
