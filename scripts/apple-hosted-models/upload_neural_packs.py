#!/usr/bin/env python3
"""Upload only the three approved new Voxamber packs; default is GET-only.

Reuses the unchanged legacy signed API/multipart/resume transport. Adds a
separate catalog, exact archive/manifest approval, inner contract/legal checks,
and API ownership binding. Does not activate downloads or touch TestFlight.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.parse

import prepare_neural_packs as builder
import upload_model as transport

ROOT = builder.ROOT
APPROVAL = builder.SPEC_ROOT / "upload-approval.json"
STATE_ROOT = ROOT / "Apple/.build/apple-hosted-neural-models/upload-state"
ALLOWLIST = {
    "intent": ("qwen3.5-0.8b-mlx-int4", "Voxamber-Qwen35-08B-INT4"),
    "image": ("sdxl-base-ios-coreml", "Voxamber-SDXL-CoreML"),
    "shape": ("hunyuan-shape-2.1-q4-30b93", "Voxamber-Hunyuan21-Shape-Q4-30B93"),
}
APP_ID, BUNDLE_ID, PLATFORM = "6831042755", "com.kaisun.voxamber", "IOS"
require = transport.require


def load_approved():
    catalog = builder.load_catalog()
    raw = APPROVAL.read_bytes(); approval = builder.strict_json(raw)
    catalog_hash = builder.digest(builder.CATALOG)
    require(approval.get("schemaVersion") == 1 and approval.get("appID") == APP_ID
            and approval.get("bundleID") == BUNDLE_ID and approval.get("platform") == PLATFORM,
            "Approval belongs to another App/platform")
    require(approval.get("catalogSHA256") == catalog_hash, "Approved catalog changed")
    require(approval.get("legacyTransportSHA256") == builder.digest(Path(transport.__file__)),
            "The trusted legacy transport changed; review before using credentials")
    rows = approval.get("packs", [])
    require(len(rows) == 3 and {p["group"] for p in rows} == set(ALLOWLIST), "Expected exactly three approved new packs")
    result = {}
    for item in rows:
        require((item["modelID"], item["assetPackID"]) == ALLOWLIST[item["group"]], "Pack is outside the new-model allowlist")
        pack = next(p for p in catalog["packs"] if p["group"] == item["group"])
        require((pack["modelID"], pack["assetPackID"]) == ALLOWLIST[pack["group"]], "Catalog pack identity changed")
        spec = builder.SPEC_ROOT / item["group"]
        source = ROOT / builder.relative_path(pack["sourceManifest"])
        require(builder.digest(source) == item["sourceManifestSHA256"] == pack["sourceManifestSHA256"], "Source manifest differs from approval")
        native = builder.strict_json(source.read_bytes())
        contract_path = spec / "model-contract.json"
        require(builder.digest(contract_path) == item["contractSHA256"], "Approved model contract changed")
        contract = builder.strict_json(contract_path.read_bytes())
        packaging = contract.pop("packaging", None)
        require(contract == native and packaging is not None
                and packaging["legalFiles"] == pack["legalFiles"]
                and packaging["sourceManifestSHA256"] == pack["sourceManifestSHA256"]
                and packaging["publicationEnabled"] is False, "Contract/model/legal scope differs")
        require(native["apple"]["available"] is False, "This uploader must not enable client availability")
        pin_id = builder.model_pin_identity(native)
        require(pin_id == item["modelPinIdentitySHA256"] == packaging["modelPinIdentitySHA256"], "Native pin identity differs")
        for legal in pack["legalFiles"]:
            builder.verify_file(ROOT / builder.relative_path(legal["source"]), legal)
        for prefix in ("archive", "manifest"):
            path = builder.relative_path(item[prefix + "Path"])
            require(path.startswith("Apple/.build/apple-hosted-neural-models/" + item["group"] + "/"), "Artifact path escaped approved staging")
            require(type(item[prefix + "ByteCount"]) is int and item[prefix + "ByteCount"] > 0
                    and re.fullmatch("[0-9a-f]{64}", item[prefix + "SHA256"]) is not None, "Invalid approved artifact identity")
        require(Path(item["archivePath"]).name == item["assetPackID"] + ".aar"
                and Path(item["manifestPath"]).name == "Manifest.json", "Artifact filename differs")
        result[item["group"]] = {"approval": item, "pack": pack, "native": native,
                                 "contractPath": contract_path}
    return result, catalog_hash, hashlib.sha256(raw).hexdigest()


def validate_manifest(manifest, approved):
    pack, native, item = approved["pack"], approved["native"], approved["approval"]
    expected = {native["apple"]["modelRootRelativePath"] + "/" + f["path"] for f in native["files"]}
    expected.update(f["relativePath"] for f in pack["legalFiles"])
    expected.add(native["apple"]["contractRelativePath"])
    selectors = manifest.get("fileSelectors", [])
    require(all(isinstance(s, dict) and set(s) == {"file"} for s in selectors), "Unsupported file selector")
    paths = [builder.relative_path(s["file"]) for s in selectors]
    require(manifest.get("assetPackID") == item["assetPackID"]
            and manifest.get("platforms") == ["iOS"]
            and manifest.get("downloadPolicy") == {"onDemand": {}}
            and manifest.get("toolsVersion", {}).get("isBeta") is not True
            and len(paths) == len(expected) == item["payloadFileCount"] and set(paths) == expected,
            "Apple manifest differs from exact approved model/legal scope")


def verify_inner_contract_and_legal(archive, approved):
    native, pack, item = approved["native"], approved["pack"], approved["approval"]
    paths = [native["apple"]["contractRelativePath"]] + [p["relativePath"] for p in pack["legalFiles"]]
    pattern = "^Contents/(" + "|".join(re.escape(p) for p in paths) + ")$"
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".inner-preflight-", dir=STATE_ROOT) as temporary:
        expanded = Path(temporary)
        result = subprocess.run(["xcrun", "aa", "extract", "-i", str(archive.path), "-d", temporary,
            "-include-regex", pattern, "-include-type", "f", "-t", "2"], capture_output=True)
        require(result.returncode == 0, "AppleArchive contract/legal extraction failed")
        files = list(expanded.rglob("*"))
        require(not any(p.is_symlink() for p in files), "Archive contains a symlink")
        actual = {p.relative_to(expanded).as_posix() for p in files if p.is_file()}
        require(actual == {"Contents/" + p for p in paths}, "Archive contract/legal file set differs")
        require(builder.digest(expanded / "Contents" / paths[0]) == item["contractSHA256"], "Archived contract differs")
        for pin in pack["legalFiles"]:
            builder.verify_file(expanded / "Contents" / pin["relativePath"], pin)
    archive.unchanged()


class ScopedAPI(transport.API):
    """Bind mutations to one allowlisted pack and its proven child resources."""
    def __init__(self, key_id, issuer, key_path, pack_id, artifacts, journal, allow_upload=False):
        super().__init__(key_id, issuer, key_path, allow_upload=allow_upload)
        require(pack_id in {value[1] for value in ALLOWLIST.values()}, "Legacy/unknown pack forbidden")
        self.pack_id, self.artifacts = pack_id, artifacts
        self.asset_ids, self.version_ids, self.file_ids = set(), set(), {}
        self.journal = journal

    @staticmethod
    def identifier(value):
        require(isinstance(value, str) and transport.ID_PATTERN.fullmatch(value), "Invalid Apple resource ID")
        return value

    def check_file(self, row):
        attrs = row["attributes"]; kind = attrs.get("assetType")
        require(kind in self.artifacts, "Unexpected upload file kind")
        expected = self.artifacts[kind]
        require(attrs.get("fileName") == expected.file_name and attrs.get("fileSize") == expected.size,
                "Upload file is not the approved artifact")
        self.file_ids[self.identifier(row["id"])] = kind

    def request(self, method, path, payload=None):
        require(method in {"GET", "POST", "PATCH"}, "Unsupported upload operation")
        require(method == "GET" or self.allow_upload, "Dry run prohibits remote mutation")
        require(path.startswith("/v1/") and "#" not in path, "Invalid API route")
        route = path.split("?", 1)[0]
        asset_versions = re.fullmatch(r"/v1/backgroundAssets/([A-Za-z0-9-]+)/versions", route)
        version = re.fullmatch(r"/v1/backgroundAssetVersions/([A-Za-z0-9-]+)", route)
        files = re.fullmatch(r"/v1/backgroundAssetVersions/([A-Za-z0-9-]+)/backgroundAssetUploadFiles", route)
        file = re.fullmatch(r"/v1/backgroundAssetUploadFiles/([A-Za-z0-9-]+)", route)
        remember = None; creating = None
        if method == "GET":
            if route in {f"/v1/apps/{APP_ID}", f"/v1/apps/{APP_ID}/appStoreVersions"}:
                pass
            elif route == f"/v1/apps/{APP_ID}/backgroundAssets":
                remember = "assets"
            elif asset_versions and asset_versions[1] in self.asset_ids:
                remember = "versions"
            elif version and version[1] in self.version_ids:
                pass
            elif files and files[1] in self.version_ids:
                remember = "files"
            elif file and file[1] in self.file_ids:
                remember = "file"
            else:
                raise transport.UploadError("GET escaped the selected App/pack resource graph")
        else:
            data = (payload or {}).get("data", {})
            attrs, relationships = data.get("attributes", {}), data.get("relationships", {})
            if method == "POST" and route == "/v1/backgroundAssets":
                require(data.get("type") == "backgroundAssets" and attrs == {"assetPackIdentifier": self.pack_id}
                        and set(data) == {"type", "attributes", "relationships"}
                        and relationships == {"app": {"data": {"type": "apps", "id": APP_ID}}}, "Asset creation escaped approved App/pack")
                remember = "asset"
                creating = "asset"
            elif method == "POST" and route == "/v1/backgroundAssetVersions":
                parent = relationships.get("backgroundAsset", {}).get("data", {})
                require(data.get("type") == "backgroundAssetVersions" and not attrs
                        and set(data) == {"type", "relationships"}
                        and parent.get("type") == "backgroundAssets" and parent.get("id") in self.asset_ids
                        and relationships == {"backgroundAsset": {"data": parent}},
                        "Version creation escaped selected pack")
                remember = "version"
                creating = "version"
            elif method == "POST" and route == "/v1/backgroundAssetUploadFiles":
                parent = relationships.get("backgroundAssetVersion", {}).get("data", {})
                require(data.get("type") == "backgroundAssetUploadFiles" and parent.get("type") == "backgroundAssetVersions"
                        and parent.get("id") in self.version_ids and set(data) == {"type", "attributes", "relationships"}
                        and relationships == {"backgroundAssetVersion": {"data": parent}}
                        and set(attrs) == {"assetType", "fileName", "fileSize"},
                        "Upload file creation escaped selected version")
                require(attrs.get("assetType") in self.artifacts, "Unapproved artifact kind")
                expected = self.artifacts[attrs["assetType"]]
                require(attrs["fileName"] == expected.file_name and attrs["fileSize"] == expected.size, "Unapproved artifact identity")
                remember = "file"
                creating = "file_" + attrs["assetType"]
            elif method == "PATCH" and file and file[1] in self.file_ids:
                expected = self.artifacts[self.file_ids[file[1]]]
                require(data.get("type") == "backgroundAssetUploadFiles" and data.get("id") == file[1]
                        and set(data) == {"type", "id", "attributes"}
                        and attrs == {"uploaded": True, "sourceFileChecksums": {"file": {"hash": expected.md5, "algorithm": "MD5"}}},
                        "Only approved file completion/checksum may be patched")
                # The completion PATCH can return a sparse row. The subsequent
                # mandatory GET verifies full identity/state/checksum again.
                remember = None
            else:
                raise transport.UploadError("Mutation escaped the selected asset upload graph")
        if creating:
            self.journal.begin(creating, baseline=self.version_ids if creating == "version" else ())
        try:
            result = super().request(method, path, payload)
        except transport.APIError as error:
            if creating and error.status < 500:
                self.journal.complete(creating)  # Definite refusal, not an uncertain success.
            raise
        rows = result["data"] if isinstance(result["data"], list) else [result["data"]]
        if remember in {"asset", "assets"}:
            for row in rows:
                if row["attributes"].get("assetPackIdentifier") == self.pack_id:
                    self.asset_ids.add(self.identifier(row["id"]))
            if remember == "asset":
                require(len(rows) == 1 and rows[0]["id"] in self.asset_ids, "Created asset identity differs")
            if any(row["id"] in self.asset_ids for row in rows):
                self.journal.complete("asset")
        elif remember in {"version", "versions"}:
            self.version_ids.update(self.identifier(row["id"]) for row in rows)
            if remember == "version" or self.journal.new_version_seen({row["id"] for row in rows}):
                self.journal.complete("version")
        elif remember in {"file", "files"}:
            for row in rows:
                self.check_file(row)
                self.journal.complete("file_" + row["attributes"]["assetType"])
        return result


class CreationJournal:
    """Before-POST durable journal, using the trusted atomic state serializer.

    An unknown asset/file creation may only be reconciled by a subsequent GET.
    Missing eventual-consistency rows cannot trigger another blind POST. Version
    creation retains the legacy baseline reconciliation as an additional guard.
    """
    def __init__(self, path, identity):
        self.state = transport.ResumeState(path, identity)

    def pending(self, key):
        record = self.state.data["files"].get(key)
        return record is not None and record.get("complete") is False

    def begin(self, key, baseline=()):
        require(not self.pending(key), "Creation outcome remains uncertain; retain state and reconcile by GET before retrying")
        self.state.data["files"][key] = {"complete": False, "completed_parts": []}
        if key == "version":
            self.state.data["baseline_version_ids"] = sorted(baseline)
        self.state.save()

    def complete(self, key):
        if self.pending(key):
            self.state.data["files"][key]["complete"] = True
            self.state.save()

    def new_version_seen(self, identifiers):
        return self.pending("version") and len(set(identifiers) - set(self.state.data.get("baseline_version_ids", []))) == 1


def preflight(approved, catalog_hash, approval_hash, state_path):
    item = approved["approval"]
    manifest = transport.Artifact.inspect(ROOT / item["manifestPath"], item["manifestSHA256"], "Manifest.json")
    require(manifest.size == item["manifestByteCount"], "Manifest size differs from approval")
    validate_manifest(builder.strict_json(manifest.path.read_bytes()), approved)
    archive = transport.reuse_verified_preflight(state_path, ROOT / item["archivePath"], item["archiveSHA256"],
        manifest, item["assetPackID"], catalog_hash)
    proof = {"contractSHA256": item["contractSHA256"], "approvalSHA256": approval_hash,
             "sourceManifestSHA256": item["sourceManifestSHA256"], "inner_contract_and_legal_verified": True}
    cached = builder.strict_json(state_path.read_bytes()) if state_path.exists() else {}
    previous = cached.get("validated_preflight", {})
    if archive is None or any(previous.get(k) != v for k, v in proof.items()):
        archive = transport.Artifact.inspect(ROOT / item["archivePath"], item["archiveSHA256"])
        transport.verify_outer_manifest(archive, manifest)
        verify_inner_contract_and_legal(archive, approved)
    require(archive.size == item["archiveByteCount"], "Archive size differs from approval")
    identity = {"app_id": APP_ID, "bundle_id": BUNDLE_ID, "platform": PLATFORM,
        "asset_pack_id": item["assetPackID"], "catalog_sha256": catalog_hash, "approval_sha256": approval_hash,
        "artifacts": {"MANIFEST": manifest.identity(), "ASSET": archive.identity()}}
    state = transport.ResumeState(state_path, identity)
    state.data["validated_preflight"] = {"archive_stat": list(archive.signature),
        "manifest_stat": list(manifest.signature), "outer_manifest_verified": True, **proof}
    state.save()
    return state, {"MANIFEST": manifest, "ASSET": archive}


def readback(api, state, artifacts, approved):
    item = approved["approval"]
    assets = api.rows(f"/v1/apps/{APP_ID}/backgroundAssets?limit=200")
    own = [r for r in assets if r["attributes"].get("assetPackIdentifier") == item["assetPackID"]]
    require(len(own) == 1 and own[0]["id"] == state.data["asset_id"], "Final asset/App identity differs")
    versions = api.rows(f"/v1/backgroundAssets/{own[0]['id']}/versions?limit=200")
    require(any(r["id"] == state.data["version_id"] for r in versions), "Final version is not owned by selected pack")
    version = api.request("GET", f"/v1/backgroundAssetVersions/{state.data['version_id']}")["data"]
    attrs = version["attributes"]; details = attrs.get("stateDetails") or {}
    require(attrs.get("state") == "COMPLETE" and attrs.get("platforms") == [PLATFORM]
            and not details.get("errors") and not details.get("warnings"), "Version is not cleanly COMPLETE")
    rows = api.rows(f"/v1/backgroundAssetVersions/{version['id']}/backgroundAssetUploadFiles?limit=200")
    require(len(rows) == 2 and {r["attributes"].get("assetType") for r in rows} == {"ASSET", "MANIFEST"}, "Final version files differ")
    checker = transport.Uploader(api, state, artifacts)
    checks = []
    for row in rows:
        kind = row["attributes"]["assetType"]
        require(checker.file_complete(row, kind), "Final file state/checksum is not verified")
        file_attributes = row["attributes"]
        server_checksum = (file_attributes.get("sourceFileChecksums") or {}).get("file")
        if not server_checksum:
            server_checksum = {"algorithm": "MD5", "hash": file_attributes["sourceFileChecksum"]}
        checks.append({"id": row["id"], "assetType": kind, "state": "COMPLETE", "byteCount": artifacts[kind].size,
            "approvedSHA256": artifacts[kind].sha256, "serverFileChecksum": server_checksum,
            "appleDeliveryChecksumMatched": True})
    return {"schemaVersion": 1, "appID": APP_ID, "bundleID": BUNDLE_ID, "platform": PLATFORM,
        "group": item["group"], "modelID": item["modelID"], "assetPackID": item["assetPackID"],
        "assetRecordID": own[0]["id"], "versionID": version["id"], "version": attrs["version"],
        "serverState": "COMPLETE", "files": checks, "errorCodes": [], "warningCodes": [],
        "contractSHA256": item["contractSHA256"], "modelPinIdentitySHA256": item["modelPinIdentitySHA256"],
        "modelFileCount": item["modelFileCount"], "legalFileCount": item["legalFileCount"],
        "availabilityEnabledByThisTask": False, "downloadOrNeuralDeviceAcceptanceClaimed": False,
        "scope": "Only new asset upload/processing; no client activation, TestFlight, review or release changes"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=("all", *ALLOWLIST), default="all")
    parser.add_argument("--key-id", required=True); parser.add_argument("--issuer", required=True)
    parser.add_argument("--key-path", type=Path, required=True)
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--parallel-parts", type=int, default=3)
    parser.add_argument("--poll-seconds", type=float, default=30)
    parser.add_argument("--timeout-seconds", type=float, default=10800)
    args = parser.parse_args()
    require(1 <= args.parallel_parts <= 8 and 30 <= args.poll_seconds <= 60 and args.timeout_seconds > 0, "Invalid upload controls")
    builder.no_symlink_ancestors(STATE_ROOT)
    approved, catalog_hash, approval_hash = load_approved()
    selected = [key for key in ALLOWLIST if args.group in ("all", key)]
    prepared = []
    # All chosen artifacts are approved before any remote mutation is possible.
    for group in selected:
        row = approved[group]; item = row["approval"]; state_path = STATE_ROOT / (group + ".json")
        with transport.lock_state(state_path):
            state, artifacts = preflight(row, catalog_hash, approval_hash, state_path)
        identity = state.data["identity"]
        journal_path = state_path.with_suffix(".creation.json")
        api = ScopedAPI(args.key_id, args.issuer, args.key_path, item["assetPackID"], artifacts,
            CreationJournal(journal_path, identity), allow_upload=args.upload)
        api.verify_target()
        prepared.append((group, row, state_path, artifacts, api, identity, journal_path))
        transport.emit("new_pack_preflight_passed", group=group, asset_pack_id=item["assetPackID"],
            archive_sha256=item["archiveSHA256"], manifest_sha256=item["manifestSHA256"],
            model_and_legal_contract_verified=True, mutation_enabled=args.upload)
    results = []
    for group, row, state_path, artifacts, api, identity, journal_path in prepared:
        if args.upload:
            with transport.lock_state(state_path):
                state = transport.ResumeState(state_path, identity)
                api.journal = CreationJournal(journal_path, identity)
                for artifact in artifacts.values(): artifact.unchanged()
                transport.Uploader(api, state, artifacts, poll_seconds=args.poll_seconds,
                    timeout_seconds=args.timeout_seconds, parallel_parts=args.parallel_parts).run()
                result = readback(api, state, artifacts, row)
                builder.write_json(builder.SPEC_ROOT / group / "upload-receipt.json", result)
                results.append(result)
        else:
            results.append({"group": group, "assetPackID": row["approval"]["assetPackID"],
                "archiveSHA256": artifacts["ASSET"].sha256, "manifestSHA256": artifacts["MANIFEST"].sha256,
                "appIdentityGETVerified": True, "archiveOuterContractAndLegalVerified": True, "remoteMutationEnabled": False})
    record = {"schemaVersion": 1, "appID": APP_ID, "bundleID": BUNDLE_ID, "platform": PLATFORM,
        "catalogSHA256": catalog_hash, "approvalSHA256": approval_hash,
        "remoteMutationEnabled": args.upload, "packs": results,
        "availabilityEnabledByThisTask": False, "downloadOrNeuralDeviceAcceptanceClaimed": False}
    builder.write_json(builder.SPEC_ROOT / (("upload-" if args.upload else "upload-preflight-") + args.group + "-receipt.json"), record)
    transport.emit("new_packs_verified", completed=len(results), upload=args.upload)


if __name__ == "__main__":
    try:
        main()
    except transport.UploadError as error:
        # Transport errors/guards deliberately contain only sanitized constants,
        # HTTP status, or public IDs; never server bodies, headers or signed URLs.
        transport.emit("error", message=str(error), http_status=getattr(error, "status", None))
        raise SystemExit(1)
    except (ValueError, OSError, KeyError, TypeError) as error:
        transport.emit("error", message="Local preflight failed; retain identical artifacts/resume state", error_type=type(error).__name__)
        raise SystemExit(1)
    except KeyboardInterrupt:
        transport.emit("interrupted", message="Retain the same approved artifacts and resume state")
        raise SystemExit(130)
