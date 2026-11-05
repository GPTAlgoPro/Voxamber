# Formal JSON completion stop

Formal `QwenEngine.generateJSON` now stops the owned producer after the **entire emitted buffer** parses as one JSON object (including the previously supported complete Markdown fences). It does not add brackets, close a fence, extract a prefix, or repair invalid output. The producer is canceled and awaited; the existing Metal stream synchronization remains in the engine. The raw diagnostic API keeps this behavior disabled by default.

The new `jsonComplete` reason is distinct from EOS and user cancellation. User cancellation and grammar failure take precedence. A fully complete object at the token limit is accepted; incomplete output still fails with `outputLimit`. The 3072-token and 16,384-byte limits are unchanged. Native scene and geometry validation remain mandatory downstream.

Seven new tests use the actual native SDK producer with synthetic logits and the same consumer as production. They cover complete JSON followed by unlimited whitespace, owned producer settlement, escaped string braces and nested objects, complete/incomplete fences, trailing garbage, diagnostic mode, exact/incomplete token boundaries, cancellation precedence, and metadata encoding. All 23 package tests passed. The arm64 iOS 26 Release package compiled successfully; the last subsequent source edit changed only the localized invalid-JSON message.

The historical screenshot/metadata establish a generation length limit. They do **not** reveal the old response buffer or prove it consisted of trailing whitespace. This change must not be presented as that diagnosis, as a phone result, or as evidence of visual modeling quality.

- [Verification and source hashes](verification.json)
- [Existing pinned weights verified](weights-verification.json)
- The separately authorized single Mac preset-context fixture is recorded under `current-preset-fixture/` after it finishes. It uses the formal API and the complete unpublished preset context, with no parameter-output fallback or replay.
