# App 6 fresh five-case single-call baseline

This protocol is fixed before model execution. It tests the current App 6 generation protocol on a Mac, not a phone and not the previous three-stage assembly experiment. Each subject gets one fresh model invocation. No preset/current scene is supplied; no response, role table, anchor plan, parameter fallback, repair, retry, or output from a previous experiment is reused.

The native API is explicitly `QwenEngine.generateJSONDirect(stopAtCompleteJSON:true,prefillStepSize:128,jsonSchema:nil,maxTokens:3072)`. The runner first saves that same invocation's returned raw text, then applies a byte-identical copy of the current production `QwenJSONObject` helper, including full-object/complete-fence validation and the 16,384-byte limit. This matches the formal wrapper's output validation while keeping rejected raw observable. It is **not** reported as a literal call to `generateJSON`. If Direct throws before returning, only observable metadata is recorded; the failed case is not rerun to obtain a replacement raw response.

One existing pinned Qwen3.5 4B INT4 model load serves five sequential cases, with a fresh request/KV cache per call, greedy temperature zero, thinking disabled, graph compilation disabled, and the unchanged current `ScenePrompt.system/userRequest`. The runtime has a 180-second generation/case deadline: the watchdog cancels and awaits the current generation; native decode/export/render have deadline checks before and after synchronous work. A synchronous renderer can return after 180 seconds, which is recorded rather than described as a hard preemptive render timeout. There is no color-edit sixth call.

## Fixed requests and execution order

1. **robot:** 做一个站立的蓝色玩具机器人，包含立方体头、躯干、左右两条手臂和两条腿，以及两个球形黄色眼睛，底部在Y=0。
2. **lamp:** 做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。
3. **whale:** 一条弯曲尾巴的蓝色小鲸鱼，流线型椭圆身体，左右鳍和分叉尾鳍，两个可见眼睛；尾鳍或侧鳍至少用一个extrusion自由轮廓。是独立海洋动物造型，不要平台。
4. **aircraft:** 带后掠机翼的未来飞行器，银色流线机身、左右对称不规则机翼、两个推进器，机翼至少一个用extrusion自由轮廓，机身可用lathe。做一个整体，不要平台。
5. **chair:** 一把简洁的棕色木椅，必须包含坐面、靠背和四条腿，地面Y=0，坐面高度约0.45米，不要增加底部平台。

These are the original five fixed QA requests, reordered robot/lamp/whale/aircraft/chair. They are not real user content. Their nouns are test cases, not a product category whitelist or native geometry template.

## Acceptance evidence fixed before execution

For every case, preserve same-call raw, terminal reason/counts, exact request/system and source/weight/runner hashes, elapsed time, and the native rejection stage when present. Native validation must retain all current limits: strict object keys and IDs, valid attachment graph, finite dimensions/transforms and free geometry, and the existing full primitive/node/profile/mesh budgets. Do not narrow these budgets or change the prompt/model to make the baseline pass.

Only an accepted scene enters the unchanged native mesh generator and GLB/USDZ exporter. Import the actual USDZ into the reused Apple SceneKit renderer, saving the unchanged front and three-quarter 900px views. Both images must be inspected for outline, proportions, actual part separation/contact and prompt fidelity before any visual judgment. JSON parsing, nonempty meshes, export, or AABB connectivity do not confer quality acceptance. AABB proximity also cannot prove actual contact for hollow/concave shapes.

- Robot: recognizable standing toy robot; cubic head with largest/smallest dimension ratio ≤1.05, torso, two distinct arms/legs, two separated yellow spherical eyes on the visible front face, and blue body. Record artistic/posture limitations separately; do not invent an unrequested arm pose as a hard failure.
- Lamp: actual gray cylindrical base, thin cylindrical vertical stem, red conical shade; actual overall height must be 0.8m ±10% (0.72–0.88m). A square base is an explicit failure. Lighting differences alone do not prove material failure.
- Whale: recognizable independent blue whale, streamlined ellipsoid body, curved tail, paired fins, forked tail fin and two visible eyes; at least one actual **nonrectangular** free extrusion profile, no unrequested platform. Valid primitive soup alone is not the requested animal.
- Aircraft: recognizable coherent silver future aircraft, swept and symmetric irregular wings, two engines, at least one actual **nonrectangular** free extrusion, no unrequested platform; assess silhouette, geometry and connections from both views.
- Chair: recognizable brown wooden chair with seat, rear backrest and four distinct grounded supporting legs; seat **upper surface** must be 0.45m ±10% (0.405–0.495m), with no bottom platform or solid base blocking the legs. Do not count overlapping legs as four visible supports. Brown material with reasonable roughness may express a low-complexity wooden style; real wood-grain textures are not a new requirement.

For grounded subjects require `abs(actual minimum Y) ≤ 1e-4m`. Approximate dimensions use the fixed ±10% tolerances above, supplied by Root **before any generation**; report absolute/relative deviations as evidence. IDs remain arbitrary: no fixed ID matching is used to generate geometry or shortcut acceptance. No new post-hoc numeric tolerance or pose rule will be introduced to turn an output into a pass. Overall visual/instruction acceptance remains pending Root's individual image review, and a missing render is not accepted. Mac latency and memory are not iPhone guarantees. All prior single-call and three-stage QA records remain unchanged.
