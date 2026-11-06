# Sampling + full structural schema: measured result

One authorized batch completed with exactly one load and five new calls, changing only the schema argument relative to the frozen sampling condition. The sampling package, seed 24301, prompts, model bits, output/prefill/KV limits, early stop and native validation remained unchanged. There was no repair, retry, fallback, old response replay, production source change, model download or phone operation.

| Case | Tokens / termination | Native artifact | Root-reported complete request acceptance |
| --- | --- | --- | --- |
| robot | 1218 / jsonComplete | GLB/USDZ + two actual PNGs | Fail: all part centers coincide; the large box hides head/limbs/eyes |
| lamp | 403 / jsonComplete | GLB/USDZ + two actual PNGs | Fail: box base and overall height 0.944m |
| whale | 1549 / jsonComplete | GLB/USDZ + two actual PNGs | Fail: vertical unshaped body, overlapping eyes and centered fins |
| aircraft | 1788 / jsonComplete | Rejected by native numeric bounds | No render/acceptance: fuselage height 3.5m exceeds 2.5m |
| chair | 1853 / jsonComplete | GLB/USDZ + two actual PNGs | Fail: front/back poles obstruct the seat instead of a normal rear backrest |

Root reported individually viewing all eight exact actual renders and **0/5 complete fixed requests accepted**. The chair's seat upper surface is 0.483m, +7.33%, within the predeclared ±10% tolerance; its failure is the backrest/placement, not an invented size failure. The child runner does not infer visual acceptance from IDs or file validity.

The structural result improved from one to four native exports compared with the sampling-only condition, but this did not establish usable scene planning. Full JSON schema supplies required fields and allowed alternatives; it cannot force meaningful distinct positions, correct part roles, contacts or requested silhouette. This run is not evidence for production promotion or general free modeling readiness.

All five callbacks recorded grammar enabled/terminated with original schema SHA-256 `fad4c0e9225540310c4eec80ee03a88ddd9a91bb94f8e7b6ef82d40103eeafc2`, compiled schema SHA-256 `b4149ac625541c2e2035a576f2b7db2c806c485bf7446fc5f301e69fd9d4a8cc`, and `floatBoundsRequireNativeValidation:true`. `jsonComplete` means the owned producer was stopped after a complete object; it is not confirmed EOS. The adapter's documented floating-bound deferral is visible in the aircraft's complete structural object with height 3.5m: the unchanged native validator correctly rejected it before export. The original schema was not weakened or rewritten in Core.

All four GLBs passed Khronos glTF Validator with 0 errors / 0 warnings. All four USDZs passed CRC, uncompressed-entry and 64-byte alignment checks, and actual Apple SceneKit import generated both views. These are format checks, not a visual pass.

The process took 108.60 seconds. Peak MLX allocation was 3,034,562,212 bytes; after unload it was 4,000 active bytes and zero cache bytes. Timings/memory are Mac observations, not speed causation, reliability or iPhone guarantees. After execution, all pinned current production/candidate/runner sources, binary, original schema, prompt/protocol and all ten weight full SHA/byte counts were unchanged.

- [Predeclared protocol](protocol-before-generation.md) and [schema-only runner diff](runner-schema-only.diff)
- [Original full schema](schema.json), [preflight](preflight.json), [before-run provenance](provenance-before-generation.json)
- [Same-call results and metadata](results.json), [native diagnostics](same-call-native-diagnostics.json)
- [After-run verification](verification-after-generation.json), [comparison](comparison.json)
- [GLB checks](format-validation.json), [USDZ checks](usdz-validation.json)
- [Robot front](robot/front.png), [robot three-quarter](robot/three-quarter.png)
- [Lamp front](lamp/front.png), [lamp three-quarter](lamp/three-quarter.png)
- [Whale front](whale/front.png), [whale three-quarter](whale/three-quarter.png)
- [Chair front](chair/front.png), [chair three-quarter](chair/three-quarter.png)

The Root-reported visual findings above are separate from the runner's automatic `pending` fields. A separately authored Root visual-review file may be added without changing these measured artifacts.
