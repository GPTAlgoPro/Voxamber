# App 6 fresh single-call baseline

The batch completed on a Mac with exactly **one model load and five model invocations**, using the existing Qwen3.5 4B INT4 weights. No preset/current scene, schema constraint, staged outline/anchor protocol, repair, retry or fallback was used. This is the App 6 single-call generation protocol, with a diagnostic API distinction: the runner calls current `generateJSONDirect(stopAtCompleteJSON:true)` and applies a byte-identical copy of the production formal JSON helper, preserving the **same invocation's raw** before validation. It is not described as a literal `generateJSON` call or as phone evidence.

| Case | Consumed tokens / reason | Case seconds | Actual outcome |
| --- | --- | ---: | --- |
| robot | 1154 / jsonComplete | 11.99 | Native decode, GLB/USDZ and two actual renders; visual review pending |
| lamp | 266 / jsonComplete | 3.41 | Native decode, GLB/USDZ and two actual renders; visual review pending |
| whale | 1217 / SDK stop | 12.24 | Same-call raw saved; malformed JSON, no asset substitution |
| aircraft | 3072 / outputLimit | 29.95 | Same-call raw ends inside the first lathe profile; no asset substitution |
| chair | 3072 / outputLimit | 30.27 | Same-call raw ends inside a node's depth value; no asset substitution |

Both exported GLBs passed Khronos glTF Validator with **0 errors and 0 warnings**. Both USDZs passed ZIP CRC, uncompressed-entry and 64-byte alignment checks, and were imported into Apple SceneKit to render the front and three-quarter views. These are file-validity facts, not instruction or visual quality acceptance. Root's individual image review remains a separate step; no missing model is counted as accepted.

The concrete rejection evidence is now from the same invocation. Whale `body.profile` has an erroneous quote before the second numeric pair and fails JSON parsing despite the SDK stopping below the cap. Aircraft already declares a 4.5m height (native maximum 2.5m), has 221 complete numeric pairs in an unclosed lathe profile (maximum 64), and is cut off at the next `[`. Chair has 44 literal ID fields before truncation (maximum 32 nodes). Counts in incomplete JSON are explicitly lexical observations, not a reconstructed or repaired scene. Full raw, parser positions and context are retained in each case and [same-call-raw-diagnostics.json](same-call-raw-diagnostics.json).

The process took 88.98 seconds including a 1.06-second model load. Peak MLX allocation was 3,034,562,212 bytes; after unload it was 4,000 active bytes and zero cache bytes. These are Mac allocator measurements, not iPhone physical memory or performance guarantees. No case exceeded the declared deadline.

After execution, all **42 pinned production files**, runner sources, compiled binary, prompt/protocol files, and all **10 weight SHA-256/byte counts** were unchanged. No production source, App pipeline, phone, account or model download was changed by this run. Prior single-call and three-stage records remain untouched.

- [Protocol and Root-fixed rubric written before generation](protocol-before-generation.md)
- [Before-run provenance](provenance-before-generation.json)
- [After-run verification](verification-after-generation.json)
- [Machine-readable batch results](results.json)
- [GLB format validation](format-validation.json) and [USDZ checks](usdz-validation.json)
- [Robot front](robot/front.png), [robot three-quarter](robot/three-quarter.png)
- [Lamp front](lamp/front.png), [lamp three-quarter](lamp/three-quarter.png)

This baseline establishes that early JSON completion alone does not remove the three observed fresh-generation failures. It does not establish overall creative quality, and it does not borrow the old three-stage experiment's acceptance score as an App 6 result.
