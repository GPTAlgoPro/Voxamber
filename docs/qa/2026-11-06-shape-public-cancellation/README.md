# Public Shape cancellation: one Mac case passed

The authorized run made one partial learned-model request through public
`ShapeEngine.generate`. After the first real denoise-step callback, the500ms
deadline fired after an observed526ms. The actual owned request returned
`CancellationError`1.016058s after cancellation; explicit unload and public idle
were observed at1.016071s. This passes the predeclared **below5s** target for
this one host case. It is not an iPhone, App UI, TestFlight or universal latency
claim, and the private checkpoint where cancellation was observed is unknown.

The first trial's sampled process footprint peaked at4,214,557,144bytes; MLX
reported4,204,812,968peak bytes. After unload, MLX active/cache were both0 and
process footprint was323,568,936bytes. The trial ended during denoising, so
these numbers are not a full-generation or phone memory acceptance result.

A second fresh public engine reached `Verifying shape model`, was immediately
cancelled and returned `CancellationError`; it never reached Loading/denoising
or Busy. It settled idle in0.000411s, with MLX active/cache still0. This is a
same-process lease-reacquisition probe, not another learned-model generation.
There were no retries, watchdog triggers, telemetry failures, or published
GLB/USDZ files. All57frozen source/object/executable/bundle/input hashes matched
afterward; the input and weight whole-file pins remained unchanged.

- `protocol-before-run.md` preserves the declaration made before GO.
- `armed-source.json` preserves the exact frozen57-file inventory and pins.
- `Sources/GateMain.swift` is a byte-identical copy of the source actually run;
  it intentionally uses the declared fixed local input/model paths.
- `actual-public-cancellation-report.json` preserves actual callbacks, monotonic
  timings, public statuses and memory observations.
- `execution-validation.json` records terminal checks and limits.

The executable, linked objects, bundles and original output remain under ignored
`Apple/.build/NativeShapePublicCancellationGate/`. The prerequisite cancellation
source and synthetic CPU numerical contracts are documented separately in
`../2026-11-06-shape-cooperative-cancellation/`.
