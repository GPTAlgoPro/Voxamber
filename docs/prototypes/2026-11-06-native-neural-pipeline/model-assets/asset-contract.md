# Native neural model resources

This controller prepares files only. It never loads MLX/CoreML, imports another app's caches, or treats the legacy Qwen4B installation as readiness for the new pipeline.

`NeuralModelManager(beforeResourceMutation:)` exposes `ready`, `busy`, `stage`, `progress`, `resources: CreationResources?`, `groups`, and `errorMessage`. The injected async hook must cancel/await/unload the pipeline before import/download mutates resources. `checkInstallation()` hashes all three private installations; `importRoots(NeuralImportRoots(intent:image:shape:))` imports the selected actual model directories, sequentially; `importModel(group:from:)`, `download(group:)`, `downloadAvailable(group:)`, `cancel(group:)`, and `waitForCurrentOperation()` are available. Cancellation of a different group has no effect. The operation's slot is retained until file-copy/Apple cleanup settles. Progress hops carry an operation UUID so late callbacks cannot update a later operation.

Private layout: `Documents/NeuralModels/<manifest.id>/`. Only exact listed regular files are copied, SHA256-verified, and atomically published using the existing `VerifiedModelStore`. Pending verified files are reusable after interruption; an incomplete replacement cannot replace a complete installation. Readiness is false while checking/installing and after an unverified failure/cancellation. A later full check can readmit surviving valid installations. `CreationResources.shapeModelFile` points directly to `model.q4.safetensors`; the sibling pinned `config.yaml` must also be present and verified. Installed files can still be altered externally after checking; backend admission remains independent.

## Bundled catalogs

`Resources/NeuralModels/IntentQwen08.json`, `ImageSDXL.json`, and `ShapeHunyuan21.json` are separately pinned. Loading supports both a `NeuralModels` resource subdirectory and Xcode flattened bundle resources. The SDXL catalog was produced by hashing its actual extracted 27-file tree; Qwen's 10 files were checked against its existing fixed manifest and local files. Shape lists the original Q4 identity while reconstruction is pending; its absence never becomes ready.

The Qwen card's Base/non-Base origin metadata conflict remains explicit; exact byte identity alone does not prove instruction-tuned provenance. Three auditable self-distributed foundation weight groups total about 7.912B parameters, with each group below 8B. Apple's private Vision foreground model is outside that auditable count. Compiled resources, disk sizes, file tests, and typechecking do not establish 6GiB phone peak memory, inference parity, speed, or 3D quality.

## Future Apple pack contract

All three `apple.available` values are **false**. Download currently reports that the new pack has not been published before touching `AssetPackManager.shared`. There is no public HTTP fallback and no implicit legacy 4B request. These proposed pack IDs are deployment contracts, not evidence that Apple has accepted or serves them:

| Group | Apple asset pack ID | Model root | Contract file |
|---|---|---|---|
| intent | Voxamber-Qwen35-08B-INT4 | models/qwen3.5-0.8b-mlx-int4 | contracts/qwen3.5-0.8b-mlx-int4.json |
| image | Voxamber-SDXL-CoreML | models/sdxl-base-ios-coreml | contracts/sdxl-base-ios-coreml.json |
| shape | Voxamber-Hunyuan21-Shape-Q4 | models/hunyuan-shape-2.1-q4 | contracts/hunyuan-shape-2.1-q4.json |

Pack contents must preserve every catalog path below the corresponding model root. The small contract file is the matching catalog JSON, outside the model root. Distinct contract paths avoid global namespace collisions across packs. Runtime contract checks compare the exact group/id/version and path/size/SHA/sourceURL pin set plus Apple pack ID/model-root path. Downloaded metadata never overrides bundled pins. Actual private import independently validates every payload SHA. Source reference URLs in the catalog are provenance; the upstream shape FP16 card is not a Q4 download endpoint.

The new adapter independently owns one catalog-selected pack and copies the proven legacy strategy: valid bundle/AppGroup/downloader extension guards before singleton access, signed StoreKit AppTransaction bundle/environment validation, exact pack status observation joined on cancellation, owned awaited pack removal, operation UUID guards, and retry cleanup. It never removes another group or private installed copy. After atomic private import succeeds it may remove only that redundant managed pack. Apple must return files in a coherent relative layout; split/non-co-located URLs fail closed. Current unavailable flags deliberately prevent claiming this future transport is exercised. The existing `Apple/ModelDownloader/Downloader.swift.shouldDownload` still whitelists only the legacy 4B pack. Publishing the new route must explicitly add these three new IDs to that extension policy as well as upload the packs and update the bundled availability flags; this task deliberately did not change the legacy extension. Publication and cold Apple download/offline device acceptance still require separate real tests.

## Validation scope

The host harness compiles the same production `NeuralModelCatalog.swift` and unchanged `VerifiedModelStore.swift`; synthetic small file fixtures test three-group admission, corruption/extra files, symlink rejection, legacy isolation, cancellation settlement and subsequent reuse, catalog safety, and deterministic content identity. Catalog tests also load the actual 10/27/2 manifests. Fixture readiness is only a file-store test, never a neural success. App tests add unpublished-download no-mutation and group-scoped cancellation/join; they are recorded separately until the full App suite executes. No real resource import or model inference was run for this feature.

## Post-commit cancellation correction

The follow-up `cleanup-verification.json` supersedes only the managed-copy ownership code evidence. After a successful private import, `NeuralManagedImport.perform` always awaits a new scoped cleanup task that does not inherit the cancelled caller flag. The manager keeps its operation busy until that helper settles. Only then can external cancellation finish; it never publishes readiness on a cancelled path or removes the private installation. Cleanup failure has its own visible, retryable error, preserved ahead of a caller-cancel message. Four additional scripted tests prove this seam without invoking Apple services; combined host file/ownership tests total 12. The initial verification receipt retains the earlier source hashes rather than being rewritten as though that defect never existed.
