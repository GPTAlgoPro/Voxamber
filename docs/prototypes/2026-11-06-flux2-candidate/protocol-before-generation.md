# Klein4B LP image gate — protocol fixed before generation

State: SDK/source preparation only. **No Klein neural inference has run.** An explicit Root GO is still required for the single `--run` condition. Current App, canonical SDXL pipeline, model manifests, Apple three packs and phone are unchanged.

## Fixed input and comparison

Read the exact original public-pipeline `intent.json`, SHA256 `b90098e80c8fc2b07e2a617a00197f63317d20273109fc79e702da138fd390c4`; require positivePrompt210 characters and empty negativePrompt. Bare positivePrompt UTF8 SHA256 `9e9508b19e9118c56f739ea9dcb0a80f516ce24e3ef1420a26a00f44a78afe02`. No Qwen0.8 retranslation, prompt rewrite/upsampling, negative-conditioning invention, Vision, Shape, seed search, retry or output repair.

> A desk lamp with a red cone-shaped shade, a gray cylindrical base, a thin cylindrical stem, and a spherical bulb, all resting on a flat surface at height Y=0, with an overall height of approximately 0.8 meters.

Use one public `FluxImageEngine.generate` call, seed24301,512×512,4 distilled steps,guidance1, prequantized affineQ4/group64 DiT and Qwen3, official small VAE. The distilled Klein route has no negative CFG input; empty SDXL negative is not passed as fictitious conditioning. This compares a whole model-route bundle to the sealed canonical SDXL768/20/g7.5 partial LP reference. It is **not** a single-variable numerical ablation and does not reuse an old generated image.

Visual acceptance stays strict: requested red **conical** shade, gray cylindrical round base, visibly thin cylindrical stem, coherent connected lamp. A gray dome with only a red cap/collar remains partial/fail. The optional spherical bulb is allowed. Y=0 and0.8m in an image do not establish metric geometry or final3D scale. A valid PNG/API return is not quality acceptance; Root must view it.

## Resource, native and lifecycle contract

14 exact local resources are pinned in `../2026-11-06-image-model-recheck/proposed-flux2-assets.json`, all14 downloaded/copied wholeSHA validated and then actually admitted by the Swift SDK verifier. Payload tensor files total4,692,595,250B, plus tokenizer/config/index files. No cache search, downloader instance, automatic network fallback or BF16→on-load quantization is allowed in the candidate. DiT loads only0/1 shards; Qwen onlymodel.safetensors; VAE onlythe root diffusion_pytorch_model.safetensors+config. Missing files, foreign tensor sets, VAE/vae subtree, wrongdtype/shape, unmapped/missing parameters fail before evaluation; Qwen's three tied unused lm_head keys are the sole explicit missing-key exception.

Native source: MIT `nanguoyu/flux-2-swift-mlx@57ad4818ecaa4367616d0c046a24e4694bb07779`, upstream MIT `VincentGourbin/flux-2-swift-mlx@315c27e83187909bc5e1f880b4850918342d891b`; MIT profiler `82eb03f594d8a4f691d1ad5ed50e52c72cbf0ff3`; MLX0.32.3/Transformers1.3.0 exact. No unlicensed facade, MPL App, CLI or training code is used by the adapter. Original source snapshots and per-file Git/whole SHA remain in ignored OriginalSources; adaptations do not claim PyTorch or0.31 numerical parity.

Bounded resident512 profile is **TE→unload TE→DiT+small fullVAE coexist during denoise→unload DiT→VAE decode**. The three components are not mutually exclusive for the full run. Candidate Mac deliberately follows the iOS-before-decode transformer release rather than upstream Mac resident-throughput behavior. Cache profile is conservative: TE256MiB (local loader no longer overrides it to512),denoise512MiB,VAE256MiB; clear cache every denoise step; aggressive eval every4blocks. These are bounded memory/residency choices, not a proven phone peak or speed claim.

Only fixed local Klein loading/unloading uses new `@concurrent` paths; existing UI-facing/unused larger-model routes are not invoked. A MainActor-origin CPU missing-file test records the actual local load boundary on non-main thread. All candidate engine instances share a full-worker singleton lease. External cancel signals the owned task, waits for the producer, synchronizes GPU streams, clears/relinquishes models/cache and releases the lease. Cold CPU preflight/idle unload do not initialize Metal. GPU/VAE work remains cooperatively cancellable; no instantaneous stop guarantee is inferred from mock tests.

Per independent image component: DiT3,875,544,576;Qwen3TE4,022,468,096;VAElearned62,373,091 plus257BN buffers/counter =62,373,348 stored elements conservatively. Image aggregate7,960,386,020; with prior intent873,438,784 andShape3,569,340,225, auditable self-distributed aggregate12,403,165,029. Each component remains below8B; the user constraint was per-model, not aggregate. Opaque AppleVision model is unknown/excluded. Header audit is independently sealed in the prior research directory; old proposal's F32-only VAE count lacked the scalarI64counter and remains historical.

## Instrumentation and stop conditions

Independent physical-footprint/MLX samples nominally every200ms; actual sample timing/gaps and stage events are retained. Do not sample MLX counters before a genuine runtime stage. Upstream resets its MLX peak counter between phases, so a single final counter is not the whole-run peak. OS sampled peak has finite cadence and is not an exact instantaneous maximum. `transformer_loading` is after TE cleanup; `vae_decoding` is after transformer release; final unload/counter snapshots must be recorded.

One owned900s QA watchdog cancels the actual generation and awaits settlement. It is not a hard GPU preemption bound. Always cancel/await watchdog, await engine.unload, join sampler and require engine.isRunning=false. Any timeout, source/pin mismatch, native generation failure, PNG/report I/O failure or live engine after cleanup causes an honest failed/exit1 receipt, no rerun. Preserve the returned PNG unchanged. No quality PASS from file/schema success.

Mac host evidence is not iPhone12GB/6GiB process-budget evidence. Phone admission, full-pipeline residue, repeated runs, actual cancel timing and visual3D quality remain open. CurrentSDK iOS admission still requires12GB physical RAM and5.5GiB available headroom; it is not weakened for this Mac gate.
