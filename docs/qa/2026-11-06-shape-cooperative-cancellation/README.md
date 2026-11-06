# Shape cooperative cancellation: source and CPU contracts

This patch adds synchronous cancellation checkpoints inside the existing Shape
denoiser execution. It does not load new model weights, run another learned
neural generation, operate a phone, or establish a device stop-time bound.

`ShapeDenoiser.forwardCancellable` is a protocol requirement, so the sampler's
`any ShapeDenoiser` existential dispatches into `DiTPlain`'s interior checks.
Other conformers retain a default check before/after their existing forward.
The original nonthrowing forward and sampler interfaces remain available.

The actual MoE chunk/expert traversal uses a small `rethrows` helper. A legacy
forward passes an empty nonthrowing check; the cancellable forward passes a
predicate that throws `CancellationError`. Checks occur at block/expert/chunk
boundaries and after existing materializations. Serialized CFG checks before
starting the unconditional branch. The throwing sampler never returns partial
latents; the throwing GLB entry propagates cancellation through the generator.
Legacy optional mesh calls retain nil-on-failure behavior. No zero tensor,
replacement mesh, abandoned detached worker, or added materialization is used.

The existing outer worker ownership, autorelease, GPU synchronization/cache
cleanup, and runtime lease settlement stay unchanged. A current MLX evaluation
cannot be interrupted. Its lazy dependency graph may include earlier dense and
attention blocks, so a checkpoint after a 512-row chunk does **not** imply that
only that FFN is pending or promise a millisecond bound. Testing learned-model
cancellation and phone behavior requires separate authorization and evidence.

Before changing the four production files, a small deterministic CPU fixture
was linked against the previous compiled module and actually evaluated. Its
five output hashes cover unchunked/chunked dense MoE, sparse MoE, and batched /
serialized CFG. These are synthetic tensors, not trained-model success cases.
The new false-cancellation paths match both that independent pre-change golden
and the retained legacy wrappers byte for byte.

Validation completed:

- 11 cancellation/dispatch/traversal/tiny CPU numerical tests passed.
- All 35 Shape SDK tests passed, including existing real CPU geometry export,
  archive, native format import, weight-profile, and cleanup contracts.
- Release arm64 iOS 26 compilation against iPhoneOS 27.2 passed.
- Static existing `eval` callsites and `clearCache` call counts match the old
  source. This is a source check, not a full weighted runtime trace.

See `validation.json` for frozen source/test hashes, the actual pre-change
golden, build details, and limitations. The ignored logs and old source snapshots
remain under `Apple/.build/ShapeCancellation/`; independent scratch directories
are `ShapeCancellationBuild` and `ShapeCancellationIOSBuild`.
