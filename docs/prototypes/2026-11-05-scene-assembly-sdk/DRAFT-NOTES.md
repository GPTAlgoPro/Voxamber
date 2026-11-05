# Isolated SceneAssembly Core candidate

This is a draft under ignored `.build`, copied from `Apple/Packages/CreationCore`.
`Package.swift`, all copied source and all copied legacy tests are preserved.
No candidate file is promoted to the App or production Core by these tests.
The public three-phase requests and canonical decoder are in
`SceneAssemblyProtocol.swift`; typed data is in `SceneAssemblyTypes.swift`.
`SceneAssemblyPlanner.swift` is owned independently and accepts an injected
async generator and awaited phase callback. The package does not depend on MLX,
model files, a script runtime, network access or platform UI.

## Meaningful differences from the frozen synthetic prototypes

- The outline contract permits a forest, including a child before its parent.
  A main root may be suggested first but neither a single root nor array position
  is enforced. This changes the experimental outline prompt's single-root sentence.
- If the model chooses multiple roots, geometry must explicitly provide `origin`
  for each root. Coordinates remain model-authored; there is no automatic layout,
  object-category rule, ID-name rule or purpose-string coordinate extraction.
  Single-root creation retains both the original grounded and absolute-origin forms.
- Placement retains optional model-authored `xOffset`, `yOffset`, `zOffset` residuals
  relative to its declared anchor. Only face-tangent fields are allowed, even when
  a prohibited normal field is zero; `inside` allows all three. Omission is distinct
  from explicit zero. Both the label and every provided residual are fixed in the
  geometry schema and decoder. This is an unmeasured candidate extension to the
  frozen anchor-only semantic and geometry prototypes.
- Each declared residual must be finite and within +/-3 meters. Combined
  anchor-plus-residual offsets must also fit the unchanged legacy +/-3m contract;
  invalid combinations throw rather than clamp, scale, change anchor, or repair data.
- Placement uses the fresh full-pipeline runner's 3072-token upper budget, as do
  outline and geometry. The earlier small semantic-only diagnostic used 768.
  Actual stopping remains with the provider/Engine; a token cap does not guarantee
  that every maximum-size contract instance fits. No part/freeform count is reduced.
- A root-only outline has an exact empty `anchors` array contract. It does not emit
  `oneOf: []` or `prefixItems: []`. The planner still awaits the placement-phase
  callback and cancellation checks but can synthesize this unique empty result,
  skipping the unnecessary neural call. Such a run has two, not three, model calls.
- Anchor extents are measured from each stripped part at origin using the actual
  rotated/nonuniform/freeform native mesh. Translation-independent extents match
  the declared prototype math without using a temporary whole-scene center layout
  that could prematurely fail the global position gate. Final translation,
  normal contact, overlap, grounding and all canonical validation still use the
  unmodified ScenePlan/SceneAttachmentResolver. A nested regression covers a
  valid anchor layout whose hypothetical center layout would exceed that gate.
- Typed outline/placement tables are serialized compactly with stable keys. Their
  text content is not filtered or assigned expected answers. The geometry request
  preserves the tested system plus the explicitly declared residual/multiple-root
  extensions, original request, model outline and model placement.

## Preserved contract and acceptance boundaries

All 32 parts, eight primitives, profile64, mesh1024 vertices/2048 triangles,
materials, rotation and root origins remain available. Geometry schema derives
from the complete authoritative schema and preserves its definitions. Unknown
and duplicate raw JSON fields, changed model IDs/type/count/graph/anchor/deltas,
invalid topology and invalid numeric values are rejected. There are no fallback
objects, automatic retries, object-name heuristics or arbitrary code execution.
The old SceneSpec/ScenePlan wire formats and editable snapshots are unchanged.

AABB attachment does not prove surface contact for hollow/concave geometry.
Zero tangent spread may collapse different anchors; the kernel does not resize or
nudge a part to disguise this. SceneSpec acceptance is not silhouette, scale,
model-intent or visual acceptance. Aggregate rendered budgets still belong to the
unchanged SceneGenerator. The inherited outline prompt's blanket closed-solid
phrase comes from the prototype and is not a new claim that arbitrary mesh/open
lathe data is closed. This candidate does not establish an edit-aware neural flow;
existing canonical ScenePlan editing is left intact.

Unit tests use synthetic typed plans and native geometry only. They establish
contract/kernel/orchestration behavior, not model output quality, iPhone runtime,
12GB memory suitability, cold download, cancellation latency or TestFlight status.
Production promotion remains a separate root review after fresh model evidence.
