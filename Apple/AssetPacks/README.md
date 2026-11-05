# Voxamber Apple-hosted model assets

This directory contains only public source contracts, packaging specifications,
reference integration code, and sanitized receipts. Weights, AppleArchives,
temporary payloads and resumable upload state live under ignored `Apple/.build/`.
The build/upload helpers run on the development Mac; neither helper nor a Python
runtime is part of the app or model asset payload.

## Exact model and payload

- App: `6831042755`, bundle `com.kaisun.voxamber`.
- Asset Pack ID: `Voxamber-Qwen35-4B-INT4`.
- Platform: iOS; policy: on demand; no language restriction.
- Model root: `models/qwen3.5-4b-mlx-int4/`.
- Ten model files match the fixed byte counts and SHA-256 values in
  `Apple/ThreeLiveStudio/Resources/LanguageModel.json`.
- Four full licenses are under `Licenses/`, alongside `model-contract.json`.
- The `chat_template.jinja` file is model text-template data, never a Python or
  JavaScript executable. No `.py`, `.js`, dylib, framework, executable or network
  helper is selected into the hosted asset payload.

`Qwen35-4B-INT4/model-contract.json` pins every model and legal file;
`catalog.json` binds the descriptor to this app. `package-receipt.json` records
the actual native archive and manifest hashes after a complete AppleArchive
extract-and-verify pass. An upload receipt is added only after Apple's GET
readbacks report completion and matching server file checksums. Upload success
does not prove that a device has downloaded or used the asset.

## Build and upload

From the repository root:

```sh
python3 scripts/apple-hosted-models/prepare_pack.py
python3 -m unittest discover -s scripts/apple-hosted-models -p 'test_*.py' -v
```

The builder verifies every source file, clones a data-only payload, invokes
Apple's `ba-package`, and checks every unpacked file again. Existing receipted
outputs are reused only when their hashes still match. It never overwrites
unreceipted artifacts.

Use `scripts/apple-hosted-models/upload_model.py --help` for upload arguments.
Supply external API key metadata and a private-key path at run time; do not put
credentials into this directory. Omit `--upload` for a read-only preflight. For
an authorized upload, pass both archive/manifest SHA-256 values from the build
receipt, a stable ignored resume-state path, and `--upload`.

The uploader is bound to this app, bundle and asset ID; uses verified TLS and
Apple-only PUT destinations; streams bounded chunks; and reconciles uncertain
version creation before another POST. Resume state contains IDs and completed
byte ranges, never signed URLs, headers, tokens or raw Apple responses.

## Main app integration, owned separately

1. Add an **ExtensionKit extension** target (`extensionkit-extension`), not a
   classic app extension. Suggested bundle ID:
   `com.kaisun.voxamber.model-downloader`. Reference source and plist are in
   `Integration/`; embed the built extension under the app's `Extensions/`.
2. Link BackgroundAssets, ExtensionFoundation and StoreKit, set iOS 26+, enable
   application-extension-only APIs and skip standalone installation. The app
   and extension must have the same version/build and signing team.
3. Register/share `group.com.kaisun.voxamber.background-assets` between both
   targets. Merge `Integration/AppGroups.entitlements` into existing main app
   entitlements rather than replacing its memory/GPU capabilities.
4. Main Info.plist needs `BAHasManagedAssetPacks=true`, `BAUsesAppleHosting=true`,
   and `BAAppGroupID=group.com.kaisun.voxamber.background-assets`. The extension
   plist uses the same group and the background-asset-downloader extension point.
5. Before accessing `AssetPackManager.shared`, non-fatally verify that the
   extension actually exists with the expected extension point and that
   `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` succeeds.
   The SDK singleton can trap when the bundle/group is malformed.
6. On explicit model installation, obtain the pack from the manager, observe
   `statusUpdates(forAssetPackWithID:)`, then call
   `ensureLocalAvailability(of:)`. For current SDKs, iOS 27 uses
   `manager.manifest.assetPack(withID:)`; iOS 26 uses `assetPack(withID:)`.
   For update checks use metadata/status APIs, not unconditional
   `checkForUpdates()`, which also starts downloads/removals.
7. Read `model-contract.json` with pack-scoped `contents(at:searchingInAssetPackWithID:)`.
   Compare it to app-owned trusted pins, then resolve **each** model URL with
   `manager.url(for: FilePath(relativePath))`. Do not assume that a common
   directory URL contains all managed files or that sibling URLs are promised.
8. Stream-copy and SHA-256-check the ten files into the existing
   `VerifiedModelStore` staging location and atomically publish only a fully
   verified installation. Never load a 3 GB weight file into one `Data` object
   merely to hash it. Keep a prior installed model usable on cancellation or
   failure. The contract's source-manifest hash records packaging provenance;
   per-file pins and the trusted contract hash are runtime integrity checks.

The reference source has not added a target or changed main app settings. A
signed development build can test entitlement guards and local assets, but
Apple-hosted cold download must be tested with the matching TestFlight app and
an Apple Account that has beta access.

Apple automatically uses the latest processed pack version for **internal**
TestFlight testing. No external Beta Review or public App Store submission is
performed by this pipeline. Device download, app import, offline inference,
version refresh and cancellation/relaunch remain separate acceptance checks.

Sources: [creating packs](https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs),
[uploading packs](https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs/),
[internal TestFlight behavior](https://developer.apple.com/help/app-store-connect/test-a-beta-version/test-apple-hosted-asset-packs/).
