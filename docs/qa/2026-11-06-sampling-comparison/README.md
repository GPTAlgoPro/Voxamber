# Isolated native sampling comparison

The authorized batch completed with **one model load and five calls**, fixed seed 24301, and no retries, repairs, preset output, model download, production source changes or phone operation. This was the whole official-derived native sampling bundle compared with the prior App 6 greedy batch; it cannot isolate presence penalty as a cause or establish backend numerical equivalence.

| Fixed case | Sampling tokens / reason | Actual native outcome |
| --- | --- | --- |
| robot | 2305 / jsonComplete | GLB/USDZ and two actual renders; Root visual review pending |
| lamp | 445 / jsonComplete | Rejected: all five nodes omit required `color` |
| whale | 1955 / jsonComplete | Rejected: `dorsal_fin.rotation` contains x without required y/z |
| aircraft | 1780 / jsonComplete | Rejected: root node includes unsupported `extra`; it also declares height 3.5m above the native 2.5m bound |
| chair | 1785 / jsonComplete | Rejected: two lathe backrest nodes omit required named `dimensions` |

All five same-call raw buffers and terminal metadata are saved. The four rejected objects were not repaired or exported. [same-call-native-diagnostics.json](same-call-native-diagnostics.json) records exact fields, native errors and additional raw observations without reconstructing an acceptable scene.

In this one seed, complete JSON objects increased **2→5**, and length stops decreased **2→0**. Native valid/exported scenes decreased **2→1**. Total consumed output tokens were 8781 in the control and 8270 in this batch; robot output itself grew from 1154 to 2305 tokens. Complete JSON and shorter expansion therefore do not establish better geometry or instruction compliance. Root's control review accepted one low-complexity robot request; the sampled robot remains a separate pending image review. No production promotion is justified by these counters.

The actual robot GLB passed Khronos glTF Validator with **0 errors / 0 warnings**. Its USDZ passed CRC, uncompressed-entry and 64-byte alignment checks and was imported into Apple SceneKit to render [front](robot/front.png) and [three-quarter](robot/three-quarter.png) views. These file-format facts are not visual acceptance.

Peak MLX allocation was 3,034,562,212 bytes; after unload it was 4,000 active bytes and zero cache bytes. Process wall time was 90.71 seconds. These are host observations, not speed or phone-memory claims: an independent Simulator UIKit test may have overlapped the batch start, and the control was sequential/nonrandom with uncontrolled cache/system state. The goal was quality and repetitive expansion, not a timing win. One fixed seed is insufficient to estimate reliability.

After execution all pinned production sources, isolated candidate/runner sources, binary, prompt/protocol files and all ten weight full SHA-256/byte counts were unchanged. The greedy control's assets were not modified or replayed.

- [Protocol declared before generation](protocol-before-generation.md)
- [Prepared source differences](prepared-diff.json), [Engine diff](candidate-QwenEngine.swift.diff), [Package path diff](candidate-Package.swift.diff)
- [Five pure native sampler/processor tests and preparation receipt](prepared-verification.json)
- [Before-run provenance](provenance-before-generation.json), [after-run full SHA verification](verification-after-generation.json)
- [Batch results](results.json), [comparison](comparison.json), [environment limitation](environment-observation.json)
- [GLB validation](format-validation.json), [USDZ checks](usdz-validation.json)

Only two copied production files differ: Package.swift redirects immutable Core/Native dependencies to their current paths; QwenEngine.swift invokes the candidate sampling factory and appends its generated-only presence component. The added wrapper ignores prompt tokens, retains all generated history within the unchanged 3072-token cap, and is recreated per request. The native SDK parameter seeds a fresh per-sampler RNG; no global seed is mutated. All prompts, output budgets, KV/prefill, early completion, cancellation/await/synchronization and formal/native validation remain the control's behavior.
