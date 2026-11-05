# Native project thumbnails

The library grid now requests a thumbnail from each saved revision's own USDZ. Apple Quick Look renders the file; file-type icons are rejected. An unavailable preview leaves the saved model intact and offers reload through the card menu.

The host Release build passed 10 tests covering coalescing, caller cancellation, renderer cancellation, late obsolete revisions, deletion, content hashes, corrupt disk images, and the immutable project boundary. Two fresh parameter-generated native meshes were exported to USDZ and rendered by the real `QLThumbnailGenerator` into distinct 256×256 PNGs. Both USDZ hashes stayed unchanged. Both PNGs were opened and inspected.

These are isolated synthetic fixtures, not AI generation acceptance or restored user projects. No phone, model inference, or Apple account was operated. iOS compilation and device behavior are separate checks handled by the combined App verification.

The service uses a single renderer queue, an 8 MiB/64-entry memory cache, a 64 MiB disk budget, and revision/content/URL-specific identities. Cancellation of one card preserves other consumers. The last consumer cancels the owned request; canceled or deleted revisions cannot publish a late cache result. Source hashes and actual PNG pixel decoding are checked before accepting cached images.

- [Machine-readable verification](verification.json)
- [Actual renderer receipt](actual-render-receipt.json)
- [Chair fixture thumbnail](chair.png)
- [Robot fixture thumbnail](robot.png)

The render timings are macOS observations with uncontrolled system cache warmth, not phone performance claims. The controlled renderer tests and real Quick Look render checks are recorded separately.
