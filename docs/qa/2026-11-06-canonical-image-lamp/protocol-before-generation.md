# One canonical-tokenizer image-only lamp comparison — armed, no NN yet

The completed baseline is the original public full-pipeline lamp call, whose exact210character positive English text was faithful but whose actual768PNG was a white helmet/bust, not a red/gray lamp. Baseline raw images and all source/evidence remain frozen. This new condition changes native CLIP pretokenization to the pinned official regex/UTF8 byte BPE. It is not a new prompt, seed search, model swap, retry or repaired baseline output.

One new public `ImageEngine.generate` call only after parent GO. It reuses the actual `intent.json` from the baseline, SHA256b90098e80c8fc2b07e2a617a00197f63317d20273109fc79e702da138fd390c4. Positive text210ASCII characters is used exactly; negative is the same empty string. Seed24301, same27 pinned SDXL resources,768²,20steps,guidance7.5,DPM Solver Multistep,reduceMemory=true,cpuAndNeuralEngine (VAE remains originalcpuAndGPU). No Qwen, Vision or Shape call. No extra warm-up/prewarm, resource-lifetime optimization, driver/CFG/scheduler/precision change, resize, prompt sanitation by hand, repair or retry. The old incorrect tokenizer is not exposed as a product setting.

The entry differs from baseline: image-only vs preceding Qwen/full CreationEngine process. Thus even a visible improvement cannot establish an unqualified sole-cause claim independent of process/cache/entry context. Source and parameter differences are declared rather than hidden. This is one fixture/one seed, not general quality or phone evidence.

Native pure CPU checks must first match complete official-reference unpadded/padded IDs on the same actual49408vocab/48894merges.11vectors cover baseline LP/vase, numbers,punctuation,hyphens,contractions,abbreviations,empty negative,special tokens,whitespace and validNFC Unicode; both EOS/zero pad conventions yield22 exact checks. SDK unit fixtures are a labeled small merge closure; the full actual-resource check is separate. Production input is normalized printableASCII English. This implementation does not emulate full ftfy repair of malformed Unicode/HTML entities; no universal malformed-text equivalence is claimed. Original Apple and new full OpenAI MIT notices are retained.

Record only public ImageEngine progress and independent OS physical footprint at nominal200ms, flush phase/step readbacks. Public `.preparingResources`→first denoise includes loading, bothCLIP encodings and firstUNet step; it cannot be labeled pure model-load duration. Lastdenoise→encodingPNG includes VAE/image conversion. Host does not invoke prewarm. The source's defer/autoreleasepool unload contract applies; there is no separate public unload method. Owned task cancellation/await and900s cooperative QA watchdog retain completion status; a synchronous CoreML call may settle after the requested timeout. Report/telemetry I/O failure fails acceptance. No hard-stop or phone latency bound is inferred.

Fixed semantic/visual rubric: image must depict an identifiable complete single desk lamp with red conical/conical-frustum shade, gray round cylindrical/disk base and thin cylindrical rod; optional spherical bulb is allowed. No helmet/bust/person or unrequested category substitution. A background is not failure by itself. Check requested parts/colors/relationships and no prominent missing/replaced part.0.8m/Y0 text is not a calibrated image/mesh measurement. This condition produces no3D/color projection and cannot claim completed full3D App acceptance. Save actual PNG even if semantically wrong; judge direct visual evidence rather than file success.

Pending one-call command (refuses an existing output):

```
Apple/.build/CanonicalImageLampGate/CanonicalImageLampGate Apple/.build/CanonicalImageLampGate/LampCanonical01
```
