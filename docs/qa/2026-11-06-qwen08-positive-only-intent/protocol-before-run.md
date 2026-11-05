# Positive-only English intent: one new controlled condition

Declared before model execution. The previous three-case intent run and every original raw/result/hash remain frozen. This is a new contract condition developed after those observed failures, not a repaired or silently retried old result. These three reused development fixtures do not establish held-out reliability.

The exact new production CreationIntentDecoder system/schema/decode source is copied byte-for-byte into a new ignored runner. The new condition asks for faithful positive English translation, constrains positivePrompt to ASCII characters (1–180), and fixes negativePrompt to the empty string in schema and decoder. The title remains in the user's language. User-requested exclusions belong in the positive description rather than being silently discarded. No topic template, per-case answer, translation after generation or response repair is inserted.

ASCII is only a character-set constraint, not proof of English meaning or prompt fidelity. The empty negative field is mechanically forced: it cannot be counted as the model learning correct negative semantics. This condition must still preserve actual requested subjects, counts, relationships, colors and materials. These three prompts have no standalone explicit exclusion clause; broader user-exclusion handling is not directly tested by them.

## Fixed model and execution

Use the unchanged complete `mlx-community/Qwen3.5-0.8B-4bit@da28692b5f139cb0ec58a356b437486b7dac7462` in place. All ten pinned files are whole-SHA/size checked before and after execution. No new model, quantization or source-pin change is made. Limited source fingerprint evidence stays in the [previous condition](../2026-11-06-qwen08-intent/README.md); it does not prove all packed matrices' origin.

Exactly one model load and three fresh calls, 512 output tokens, greedy0, prefill128, no thinking, exact new schema and early complete-JSON stop. Runtime/cache/cancel/await/unload use the same formal QwenNative package. No sampling candidate, additional warm-up, sixth call, image, shape, App project or phone operation is part of the run.

The diagnostic seam remains Direct + byte-identical production QwenJSONObject + exact CreationIntentDecoder. Save the same invocation's raw before validation, never retrieve replacement raw by replaying a failure. A 180-second watchdog cancels and awaits the real owned task. The native process arms after complete file verification; parent gets its live handle before RUN triggers the single batch.

## Same three prompts, same order

1. lamp: 做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。
2. spiral_shell_vase: 一个螺旋贝壳造型的蓝色花瓶，瓶口带金色细边。
3. violin_and_bow: 一把小提琴和一根琴弓，作为两个独立物体完整入镜。

The model receives only each original prompt above plus the new current system/schema. The review table below is not sent as an answer table.

## Semantic acceptance declared before RUN

Separate schema/ASCII/empty-negative enforcement from genuine semantic preservation. Read raw and decoded text. A missing requirement remains partial/failure even when JSON and decoder pass.

- All titles retain Chinese user language. Positive text must be intelligible English, not merely ASCII gibberish. Negative is exactly empty by contract, without credit as independent model behavior.
- Lamp: one desk lamp; red conical shade, gray cylindrical base, thin cylindrical stem, grounded composition and approximate 0.8m height intent. Optional spherical bulb may be included or omitted. Ground wording suffices for Y=0 because the system forbids coordinate output. Do not require an unrequested pose, new stem color or new material texture.
- Vase: one blue spiral/seashell-form vase, with the gold detail specifically at its rim. Generic blue vase or unrelated shell object is not full acceptance.
- Violin/bow: one violin and one musical bow, two distinct objects, both complete in frame. No guitar, archery bow or fused-single-object substitution. Do not add a brown/wood-grain requirement absent from this prompt.
- Do not invent an unrequested object or erase requested relationships to fit the character limit. Do not add a new post-hoc scoring tolerance to turn a partial result into a full pass.

Results are Mac helper-stage observations only. They cannot demonstrate reference image quality, true neural mesh quality, phone performance, final App acceptance or all-topic success rate. No source is changed to make the candidate pass, and no second model batch is implied.
