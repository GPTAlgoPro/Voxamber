# Qwen 0.8 intent helper: fixed three-case test

Declared before any model load or generation. This tests only the current text-to-intent helper on a Mac. It does not generate an image, a mesh, or an App project and is not a phone or final modeling-quality acceptance test. Production App/SDK/source pins/model selection remain unchanged.

Use the already downloaded complete `mlx-community/Qwen3.5-0.8B-4bit@da28692b5f139cb0ec58a356b437486b7dac7462`. Every one of the same ten pinned files is whole-SHA/size checked before loading and again after final unload. Leftover download `.parts/.ranges` and the license are not silently counted as runtime model files.

The model card's frontmatter/body disagree about Base versus post-trained source. Official repository metadata and small HTTP206 headers/floating norms are separately recorded. The norm comparison accounts for the pinned MLX Qwen35 +1 BF16 normalization conversion. A sampled norm fingerprint does not prove every packed matrix's source, nor does it imply helper semantic quality. No full official BF16 weights are downloaded and no model is automatically replaced.

The runner compiles an exact byte copy of `VoxamberCreationNative/CreationIntentDecoder.swift` and the exact CreationIntent/error type declarations extracted from current CreationTypes.swift. Its system and JSON schema bytes are emitted to `fixed-requests.json` and compared to that source snapshot. It depends on the formal `Apple/Packages/QwenNative`, not a sampling candidate. It uses one load, exactly three fresh calls, no history/current scene, 512 output tokens, prefill128, greedy temperature0, no thinking, the exact intent schema, and early complete-JSON stop. Standard engine maxKV8192/compilefalse/lifecycle remain unchanged.

The API distinction is explicit: `generateJSONDirect(stopAtCompleteJSON:true)` saves the same call's raw before applying a byte-identical production QwenJSONObject formal helper and the exact production CreationIntentDecoder. This is equivalent output validation with raw observability, not a literal call to generateJSON. A Direct failure is not rerun to obtain raw. No response edits, template answers, fallback prompts or retries are permitted. A 180-second watchdog cancels and awaits the actual owned call; unload follows all calls. No sixth/extra warm-up inference is performed.

The process first arms on stdin after full file verification. It loads no model before receiving RUN. The parent receives its live process handle before that start signal.

## Fixed order and prompts

1. lamp: 做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。
2. spiral_shell_vase: 一个螺旋贝壳造型的蓝色花瓶，瓶口带金色细边。
3. violin_and_bow: 一把小提琴和一根琴弓，作为两个独立物体完整入镜。

The second and third are newly declared held-out synthetic requests, not user content and not a product category list. Only the actual user prompt above and the current production system/schema enter each inference. The following review criteria are not supplied as per-ID answer tables to the model.

## Predeclared semantic review

Report syntax/schema/native intent decoding separately from semantic acceptance. Review exact raw and decoded strings, not just a JSON success counter.

- All titles should retain the Chinese user's language; positive/negative prompts should be concise English and stay within the unchanged decoder limits. Do not use normalization or translation after generation to rescue a response.
- Lamp: one desk lamp with red conical shade, gray cylindrical base, thin vertical cylindrical stem, grounded/full-subject composition and approximate 0.8m overall intent. The spherical bulb is optional, not a mandatory extra object. No square-base substitution. Geometry coordinates are forbidden by the production system, so wording such as grounded/standing suffices for the Y=0 intent.
- Vase: one vase with a spiral/seashell form, blue body and gold detail specifically on the rim. Mere generic blue vase or replacing the requested spiral with an unrelated object is not full acceptance. No new dimensions/pose/material requirements are introduced.
- Violin/bow: one violin and one musical violin bow, explicitly preserved as two separate subjects, both complete in frame. Do not accept a guitar, a bow-and-arrow, or a prompt for one fused object. No unrequested color or wood-grain requirement.
- Negative prompts must not contradict required counts, colors or components. In particular, a blanket ban on multiple objects conflicts with the two-object case; a ban on unrequested extra objects does not.

A brief that omits a required relationship/color/count is partial or failed even if it decodes. No numerical score or post-hoc tolerance is added to manufacture a pass. Three one-shot synthetic helper calls cannot estimate broad reliability or prove the image/shape model will preserve their content.
