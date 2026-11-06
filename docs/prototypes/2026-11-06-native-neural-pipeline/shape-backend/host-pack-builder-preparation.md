# Host pack builder preparation

The isolated NativeShapePackBuilder compiled in Release under original MLX0.31.4. Its safe describe mode ran without reading weights/quantizing; an unsupported Q8 invocation was rejected before source or GPU operations. No actual packing, neural inference, phone or source-download-handle operation occurred.

The builder reuses the exact original Snap merge21 numerical recipe, all-expert traversal, group64, sensitive-layer skips, unused VAE-encoder drop and original metadata. The new outer gate validates all three source bytes/SHA and pinned sibling config before executing. It refuses an existing output and checks produced bytes/SHA against69cd. A nonmatching output is retained for parity investigation but rejected for import; the SDK pin is not changed.

The old submodule network checkout was stopped only after verifying the exact required git commits already existed in this project's own caches. Local git archives preserve those code trees and avoid redundant transport. Source dependency pins are recorded separately; the SDK/App still uses0.32.3 and does not link this older Host runtime.

See [builder source provenance](host-pack-builder-provenance.json), [exact dependency trees](host-builder-dependency-pins.json), and ignored `Apple/.build/NativeShapePackBuilder/README.md` for the future invocation. Raw source files are owned/downloaded by Root; this agent neither restarts nor polls their handles. The exact public2.49GB single-file pack URL was not found: it is an offline repack used by the existing Snap Apple asset. Its three pinned FP16 source files are a different7.366GB identity and require this reproducible conversion.
