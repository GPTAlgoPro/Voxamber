# Native neural text-to-3D route

The selected path is a small Qwen translator → Apple Core ML SDXL → dedicated Hunyuan3D-2.1 image-to-shape, with strict stage unload/await. Qwen does not invent primitive coordinates. Shape is a genuine learned image-to-mesh foundation model and returns independent mesh buffers/artifacts, not a fabricated SceneSpec or preset.

The three self-distributed foundation-weight groups conservatively total **7,911,616,876 original scalar weights**: Qwen3.5-0.8B full official checkpoint 873,438,784; SDXL all original components including complete VAE 3,468,837,867; deployed Shape 3,569,340,225. Shape includes all DiT experts, the actual VAE decoder and DINOv2-L. Its unused point-cloud encoder is genuinely absent from the existing inference pack; counting that unused original source encoder would produce a different 8.025B source-tree total. Quantization reduces storage, not the parameter count. See parameter-header-audit.json for exact component boundaries and bounded header reads.

The current pinned mobile shape pack is **2,490,378,616 bytes**, SHA-256 `69cd908e83bbf51200c63a2a163e2dfd34d2be0571c33b92f4a922489c564842`. It uses packed Q4 bulk DiT/DINO linears, retained FP16 VAE/embeddings/norms/router-sensitive layers, 4096 latent tokens, 10 denoise steps, octree192, serialized CFG and dense MoE chunks512. Lowering trained latents is not a valid invisible optimization: existing records report broken shape at2048 and empty mesh at1024.

Local historical evidence is Snap3D/docs/HUNYUAN_MOBILE_PIPELINE.md:205–224 and docs/plans/2026-08-31-ios-mac-parity-and-product-ui-design.md:62–96. An iPhone17ProMax/iOS27 Release development test host completed this shape path in **281.93s**, producing153,894vertices/307,320triangles and GLB+USDZ, with initial process headroom6,354,434,112B (about5.92GiB). Its exact phone shape peak was not recorded in that table. The **4.43GiB** footprint belongs to the separate Mac execution-strategy comparison, not the phone. Therefore a measured physical peak inside the target6GiB App budget, repetition, thermal and bounded single2.1 cancellation still require device evidence. Compilation at MLX0.32.3 is not parity with the historically measured0.31.4 runtime.

Existing reusable code covers native DINO/DiT/MoE/VAE, SDF/octree/marching cubes, real GLB and compliant USDZ, manifest/hash streaming, image conditioning, stage ownership and explicit cancellation tokens. Current Snap3D accepts images; its prompt factory sends users to an external image generator. Native text-to-image is a missing integration, now assigned to the separate VoxamberImageNative package. Apple publishes a31s SDXL768²/20step iPhone15ProMax observation, but no6GiB-process peak guarantee. Its memory must be measured in this actual staged App.

Other integration gaps are explicit: align the Shape package from MLX0.31.4 to0.32.3 and test numerical/geometry parity; bridge parent Task cancellation into its real detached worker token and await actual completion; unload CoreML before Shape admission; introduce a neural-mesh project type because the historical153k/307k mesh exceeds the old SceneSpec and exporter caps; preserve nonmetric/model-relative scale; and add artifact/quality/device acceptance. Do not silently simplify the mesh or substitute a preset. HunyuanShape's per-step denoise polling does not establish a few-second cancellation bound inside a long DiT forward.

This initial self-distributed ≤8B weight count does **not** include another neural PBR model. Apple Vision foreground segmentation is a system model with private/unknown parameter count and is outside this auditable total. SDXL must load only the counted UNet, two text encoders and VAE: no uncounted SafetyChecker, Refiner or other neural component. A bare shape is not claimed as full generated PBR, arbitrary CAD editing, metric accuracy, multiview observation or all-topic success. Additional learned paint components require their own parameter/memory/license decision and cannot be silently omitted from the count.

Source and model licenses are distinct. The Swift port is MIT; Qwen is Apache2.0; SDXL model weights use OpenRAIL++; Tencent Hunyuan3D2.1 has its own community agreement, distribution/notice/use obligations, excludes EU/UK/SouthKorea, and has a separate-license threshold for licensees above1million MAU at the stated reference date. Mainland use is not a worldwide distribution grant. No legal or store approval is inferred from source compilation.

Primary sources:

- [Tencent architecture,3.3B published model label and upstream10GB PyTorch VRAM](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)
- [Pinned Tencent license](https://huggingface.co/tencent/Hunyuan3D-2.1/blob/0b94677654c57bb9a6b6845cd7b704ccf551d327/LICENSE)
- [Qwen3.5-0.8B model and Apache license](https://huggingface.co/Qwen/Qwen3.5-0.8B)
- [Pinned Apple SDK and iPhone performance benchmark](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/ea2805dc1945be20561c77e5f6d1d9a5a637cda2/README.md#performance-benchmarks)
- [Pinned Apple CoreML SDXL iOS resource pack](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios/tree/ef92c54fe816c826f5328709b545338518d08db7)
- [Native Swift port, distinct from official Tencent PyTorch](https://github.com/ZimengXiong/Hunyuan3D-Swift)

The read-only audit did not modify or launch Snap3D or its unrelated dirty SUPRA-Tex goal. It did not download weights or operate a phone. New SDK sources are isolated under VoxamberShapeNative with pinned provenance.

Input-contract clarification: historical SingleImage21 passes transparentSubject-derived PNG to Shape. The vendored preprocessor alpha-bounds/recenters and only then composites white; Root foreground preparation preserves alpha, while white is a display composition. No shape-algorithm change is made.
