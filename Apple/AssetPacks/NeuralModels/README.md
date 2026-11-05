# New native model packs: local preparation only

These are three independent, data-only Apple-hosted pack candidates for App
`6831042755` / `com.kaisun.voxamber`. They do not replace the legacy Qwen 4B
catalog, pack, receipts, uploader, or client allowlist. Nothing in this directory
uploads an asset, enables `available`, or submits an App Store review.

| Group | Asset Pack ID | Model files | Exact model bytes | Parameters counted |
| --- | --- | ---: | ---: | ---: |
| Intent | `Voxamber-Qwen35-08B-INT4` | 10 | 645,315,928 | 873,438,784 |
| Reference image | `Voxamber-SDXL-CoreML` | 27 | 3,052,951,670 | 3,468,837,867 |
| Shape | `Voxamber-Hunyuan21-Shape-Q4-30B93` | 2 | 2,490,380,596 | 3,569,340,225 |
| Total | Three separate downloads | 39 | 6,188,648,194 | 7,911,616,876 |

The total conservative deployed parameter count stays below the existing
8,000,000,000 budget. This is a parameter accounting boundary, not an iPhone
memory or latency measurement. The stages run separately; packaging does not
prove that any stage or the complete pipeline succeeds on a phone.

`catalog.json` freezes each App-owned manifest's complete SHA, model/pack ID,
source directory, declared parameter count, and every required legal file's
bytes/SHA. Source manifests remain owned by the App/SDK agents. An altered
snapshot fails preparation and requires explicit review of a new catalog.

Each group contains a generated `asset-manifest.json` and `model-contract.json`.
Contracts retain the native `NeuralModelManifest` fields and add a packaging
object with legal-file pins. Native Codable ignores that extra packaging object;
its file-pin identity remains equal to the App's exact projection. The separate
Foundation-only `verify_neural_contracts.swift` checks this with Swift's actual
JSONEncoder. Model roots, contract paths, and legal paths are unique per pack,
so the managed namespace does not depend on same-name files from another pack.

Model bytes, AppleArchives, extracted payloads, and compiled host helpers stay
under ignored `Apple/.build/apple-hosted-neural-models/`. The host Python and
Swift tools are never selected into the App or archive payload. The selected
`chat_template.jinja` is tokenizer template data; Core ML `.mil` and `.bin`
files are the pinned native model resources. No source scripts, framework,
dynamic library, or executable-mode file is accepted as payload.

## Reproduce the local preparation

From the repository root, with the three already downloaded model directories:

```sh
python3 -m unittest discover -s Scripts/apple-hosted-models -p test_neural_packs.py -v
python3 Scripts/apple-hosted-models/prepare_neural_packs.py preflight
python3 Scripts/apple-hosted-models/prepare_neural_packs.py package
```

Optional `--source-intent`, `--source-image`, and `--source-shape` specify an
alternative local source directory; all pinned bytes/SHA still have to match.
`--group intent`, `--group image`, or `--group shape` limits one operation.
`specifications` emits only the contracts and manifests without reading weights.

The executable native packaging operations are:

```sh
xcrun ba-package evaluate /absolute/path/to/asset-manifest.json
xcrun ba-package package /absolute/path/to/asset-manifest.json --output-path /absolute/path/to/model.aar
xcrun aa extract -i /absolute/path/to/model.aar -d /absolute/path/to/roundtrip
```

The first two commands run with the staged payload as the current directory.
The builder APFS-clones only explicitly selected files, verifies every cloned
file, evaluates the iOS/on-demand manifest, builds with Apple's native tool,
extracts the actual archive with `aa`, then checks the exact file set and every
model, legal, and contract byte again. The final archive and generated outer
`Manifest.json` receive their own byte counts/SHA in `package-receipt.json`.
Previously receipted outputs are reused only after their hashes still match;
unreceipted outputs are preserved and refused rather than overwritten.

The Foundation check can be repeated without any model framework:

```sh
xcrun swiftc -parse-as-library Scripts/apple-hosted-models/verify_neural_contracts.swift -o Apple/.build/apple-hosted-neural-models/verify-neural-contracts
Apple/.build/apple-hosted-neural-models/verify-neural-contracts Apple/ThreeLiveStudio/Resources/NeuralModels/IntentQwen08.json Apple/AssetPacks/NeuralModels/intent/model-contract.json Apple/ThreeLiveStudio/Resources/NeuralModels/ImageSDXL.json Apple/AssetPacks/NeuralModels/image/model-contract.json Apple/ThreeLiveStudio/Resources/NeuralModels/ShapeHunyuan21.json Apple/AssetPacks/NeuralModels/shape/model-contract.json
```

## Identity and acceptance boundaries

The separate `upload_neural_packs.py` adapter reads `upload-approval.json` and
supports only these three new IDs. Its default mode verifies the exact archive,
outer manifest, extracted inner contract/legal files, and the target App using
GET. The explicit `--upload` mode reuses the unchanged legacy signed transport,
bounded multipart streams, checksum checks, and version reconciliation, with an
additional resource-ownership fence and durable creation journal. A request
whose creation outcome is unknown must be reconciled by GET; it cannot blindly
create another asset, file, or version. Resume state stays under ignored
`Apple/.build/apple-hosted-neural-models/upload-state/`, without signed upload
URLs, authentication headers, tokens, or private-key contents. The API private
key remains outside the repository. No beta group, review, release, client
availability, or extension setting is changed by this tool.

```sh
python3 -m unittest discover -s Scripts/apple-hosted-models -p test_neural_upload.py -v
python3 Scripts/apple-hosted-models/upload_neural_packs.py --key-id KEY_ID --issuer ISSUER_ID --key-path /outside/repository/AuthKey.p8
```

Add `--upload` only for an authorized transfer of these exact approved archives.
Sanitized upload receipts are written only after fresh GET readbacks show clean
`COMPLETE` states and matching delivery checksums for both files and the version.
This does not establish TestFlight download or neural/device acceptance.

- Intent uses the fixed 0.8B quantized repository snapshot. The card's Base vs
  non-Base ambiguity and the three controlled translation conditions remain in
  `docs/qa/2026-11-06-qwen08-*`; a correct file hash does not erase semantic
  failures or establish every source tensor's origin.
- Image uses Apple's fixed compiled SDXL snapshot. Its model license and Apple
  source license accompany the archive. The original model's use restrictions
  remain applicable when integrating and distributing it.
- Shape is the distinct `30b93...` rebuild, with all 2,357 tensor values checked
  against its three fixed FP16 sources and original MLX 0.31.4 recipe. It is not
  claimed equivalent to the unavailable legacy `69cd...` pack. The frozen
  contract explicitly leaves MLX 0.32.3 neural/device acceptance unverified.
  The full Tencent license/notice and source attributions accompany the data;
  its stated territory restrictions remain in the frozen source contract.

Actual neural inference, complete text-to-shape visual quality, 12GB-phone
acceptance, Apple upload/processing, TestFlight cold download, cancellation,
and offline use remain distinct gates. All three App source manifests continue
to have `apple.available=false`; no extension allowlist is changed here. The
legacy uploader is still intentionally limited to its legacy asset ID and must
not be used for these new archives without a separately reviewed adaptation.

Apple documents `ba-package` manifests and archive creation in
[Creating managed asset packs](https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs).
The app and asset-pack identifier establish the hosted identity, and upload
processing is a later step described in
[Upload Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs/).
