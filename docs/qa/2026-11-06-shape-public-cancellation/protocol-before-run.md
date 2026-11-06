# Armed public Shape cancellation acceptance (not run)

No neural call is permitted until the parent explicitly gives GO. The runner
uses only public `ShapeEngine` methods; it does not call the private backend,
denoiser, or runtime lease implementation. It runs no image/Qwen/Vision model,
does not operate a phone, and does not publish GLB/USDZ or a project revision.

Fixed first request: the already verified vase prepared512 PNG
`docs/qa/2026-11-06-native-image-vase/reference-prepared-512-rgba.png`,
249,722 bytes / SHA256
`1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae`;
the distinct `30b93` Q4 pack, 2,490,378,518 bytes / SHA256
`30b93ce8a801551b905c35d1203d71d947a6b35b3d271aa5820b11d40faf45c7`;
profile `native-rebuild-20261106-q4-30b93ce8`, existing Float64 finite/nonzero
cleanup, unchanged bundled YAML, 4,096 latents, 10 denoise steps, guidance5,
seed24301, octree192, serialized CFG and MoE512-token chunks.

The first real public progress callback `Denoising (1/10)` follows the first
completed denoise step. A stored timer requests cancellation at its monotonic
ContinuousClock timestamp plus500ms. It cancels the actual stored request Task
and calls public `engine.cancel()`. The runner awaits the public generate Task,
the owned timer, explicit `engine.unload()`, and public idle status. It records
the cancellation request, public CancellationError return (which includes the
SDK's owned-worker settlement), unload, idle, OS footprint, and MLX allocator
residuals. It cannot observe a precise private worker instruction or identify
the particular chunk where cancellation was first checked. A current lazy MLX
evaluation can still include earlier dense/attention dependencies and cannot be
preempted; no512-FFN or millisecond upper bound is asserted.

One overall900s watchdog deadline covers both calls, requests cancellation and
awaits actual settlement; it is not
a hard preemption deadline. A timeout, unexpected success, non-CancellationError,
missing first step or cancellation request, non-idle status, or I/O failure is a
failed first trial. It is never retried. Every sampler, watchdog, delay timer,
and generation Task is owned and joined. An early cancel is sticky until the
request Task is assigned, avoiding the assignment race.

For this one host case, the observed request-to-unload-idle duration must be
below5s to pass the stated regression target. This is a predeclared observation
criterion, not a universal time guarantee or a promise for the phone.

Only if the first trial meets its contract, a second fresh public ShapeEngine
call acts as a **no-NN lease probe**: its first `Verifying shape model` callback
immediately cancels its actual owned request. It must reach that callback,
return CancellationError and settle idle; it must not report Busy or reach
`Loading shape model`/denoising. This checks that the global lease can be
reacquired within the same process without deliberately loading/running a second learned model. Failure
does not trigger another probe. The public API's normal internal validation may
read a bounded part of the weight file before cancellation is observed.

`--arm` performs only CPU byte/SHA/PNG/YAML preflight and exits. The explicit
`--run` mode additionally waits for the exact stdin line `RUN` before making any
public generation call. The output destination must be new; a failed trial's
directory remains unchanged for diagnosis. Source, compiled objects, executable,
bundles, input and model pins are sealed before GO and checked again afterward.
The detailed report is written atomically at checkpoints and on completion;
report-write failure exits nonzero rather than being suppressed.

Arming command:

```sh
Apple/.build/NativeShapePublicCancellationGate/NativeShapePublicCancellationGate --arm
```

After explicit parent GO, the only execution command is:

```sh
Apple/.build/NativeShapePublicCancellationGate/NativeShapePublicCancellationGate --run Apple/.build/NativeShapePublicCancellationGate/VaseCancel01
```

Supply `RUN` once to that owned process. This is one partial learned-model
request plus at most one early-cancel public no-NN probe, not a full-generation,
image-quality, App UI, TestFlight, or iPhone acceptance test.
