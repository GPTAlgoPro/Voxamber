# Voxamber Flux candidate SDK

Isolated native Swift/MLX candidate for Klein4B affine Q4, Qwen3-4B affine Q4 and the official small VAE. The package/module name remains VoxamberFluxCandidate while this candidate is under evaluation. It is not the current App image default or an iPhone-validated release.

All 128 imported source/config/license files match the frozen SDK byte for byte; see source-provenance.json. MIT core fork: nanguoyu/flux-2-swift-mlx@57ad4818ecaa4367616d0c046a24e4694bb07779; upstream VincentGourbin@315c27e83187909bc5e1f880b4850918342d891b. The Apache2/MIT notices are under Legal/. MLX 0.32.3 and Transformers 1.3.0 are exact dependencies. No weights or Python/JavaScript runtime are embedded.

The public FluxImageEngine verifies all 14 local file SHA256 values, uses fixed file lists, rejects BF16/partial Q4 fallbacks, owns a full-period singleton lease and joins cleanup on errors or cancellation. Text weights unload before DiT plus small VAE; DiT unloads before decoding. This is a bounded profile, not mutually exclusive residency for all three components.

The sole Mac LP image trial returned a red conical shade, gray cylindrical base and thin stem in about 14 seconds. It also added a power cord. This proves neither metric height/Y0, full 3D quality, broad prompt reliability, real-device latency, offline download, repeat-cycle memory nor iPhone cancellation. Complete evidence is under docs/qa/2026-11-06-flux2-image-lamp from the repository root. Models remain only in ignored local storage. Do not change App manifests, hosting contracts or release branches merely because this candidate compiled.
