#!/usr/bin/env python3
"""Host-only, offline staging/verification of three new native model asset packs.

Uses Apple's ba-package and aa. Does not upload, change App/SDK manifests, enable
downloads, or touch the legacy Qwen 4B catalog. No interpreter enters payloads.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SPEC_ROOT = ROOT / "Apple/AssetPacks/NeuralModels"
CATALOG = SPEC_ROOT / "catalog.json"
DEFAULT_OUTPUT = ROOT / "Apple/.build/apple-hosted-neural-models"
GROUPS = frozenset(("intent", "image", "shape"))
FORBIDDEN_SUFFIXES = frozenset((".py", ".pyc", ".js", ".dylib", ".so", ".exe", ".sh"))
OFFICIAL_SOURCES = [
    "https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs",
    "https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs/",
]


def require(value, message):
    if not value:
        raise ValueError(message)


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON number")))


def relative_path(value):
    require(isinstance(value, str) and value and len(value.encode()) <= 1024,
            "Invalid relative payload path")
    require(not value.startswith("/") and "\\" not in value and "%" not in value
            and all(ord(c) >= 32 and ord(c) != 127 for c in value), "Unsafe relative path")
    require(all(part not in ("", ".", "..") for part in value.split("/")), "Unsafe path component")
    require(PurePosixPath(value).suffix.lower() not in FORBIDDEN_SUFFIXES,
            "A script/runtime executable cannot enter an asset pack")
    return value


def no_symlink_ancestors(path):
    path = Path(os.path.abspath(path))
    for item in [*reversed(path.parents), path]:
        if item.exists() or item.is_symlink():
            require(not item.is_symlink(), "Symlink source/output ancestor is not permitted")
    return path


def file_identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def digest(path):
    path = no_symlink_ancestors(path)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode), "Expected a regular file")
        h = hashlib.sha256()
        for data in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(data)
        require(file_identity(before) == file_identity(os.fstat(stream.fileno())), "File changed while hashing")
    return h.hexdigest()


def validate_pin(pin):
    relative_path(pin["relativePath"])
    require(type(pin["byteCount"]) is int and pin["byteCount"] > 0, "Invalid pinned byte count")
    require(re.fullmatch("[0-9a-f]{64}", pin["sha256"]) is not None, "Invalid SHA-256")


def verify_file(path, pin):
    validate_pin(pin)
    path = no_symlink_ancestors(path)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and not before.st_mode & 0o111,
                "Payload files must be non-executable regular files")
        require(before.st_size == pin["byteCount"], "Pinned size mismatch: " + pin["relativePath"])
        h = hashlib.sha256()
        for data in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(data)
        require(file_identity(before) == file_identity(os.fstat(stream.fileno())), "Source changed while hashing")
    require(h.hexdigest() == pin["sha256"], "Pinned digest mismatch: " + pin["relativePath"])


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if path.exists() and path.read_text() == text:
        return
    path.write_text(text)


def run(*arguments, cwd=None):
    result = subprocess.run([str(a) for a in arguments], cwd=cwd, capture_output=True, text=True)
    require(result.returncode == 0, "Native packaging command failed: " + str(arguments[0])
            + " (diagnostics retained in memory; no credentials are requested)")
    return result.stdout


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)


def model_pin_identity(manifest):
    # Mirrors NeuralModelManifest.pinIdentity: sortedKeys + withoutEscapingSlashes,
    # optional File.sourceURL omitted when absent. Names/URLs here are ASCII.
    files = []
    for item in sorted(manifest["files"], key=lambda item: item["path"]):
        row = {key: item[key] for key in ("path", "byteCount", "sha256")}
        if item.get("sourceURL") is not None:
            row["sourceURL"] = item["sourceURL"]
        files.append(row)
    pins = {"formatVersion": manifest["formatVersion"], "group": manifest["group"],
            "id": manifest["id"], "files": files}
    data = json.dumps(pins, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(data).hexdigest()


def load_catalog():
    catalog = strict_json(CATALOG.read_bytes())
    require(catalog.get("schemaVersion") == 1 and catalog.get("appID") == "6831042755"
            and catalog.get("bundleID") == "com.kaisun.voxamber"
            and catalog.get("publicationEnabled") is False, "Wrong app or enabled publication")
    packs = catalog.get("packs", [])
    require(len(packs) == 3 and {p["group"] for p in packs} == GROUPS, "Expected the three new model groups")
    require(len({p["modelID"] for p in packs}) == 3 and len({p["assetPackID"] for p in packs}) == 3,
            "Pack/model IDs must be unique")
    require(all(p["assetPackID"] != "Voxamber-Qwen35-4B-INT4" for p in packs), "Legacy pack is forbidden")
    counts = [p["parameterCount"] for p in packs]
    require(all(type(n) is int and n > 0 for n in counts), "Invalid parameter counts")
    require(sum(counts) == catalog["deployedParameterCountConservative"] <= catalog["parameterBudgetMaximum"] == 8_000_000_000,
            "The original total 8B parameter budget must not increase")
    return catalog


def specifications(pack):
    source = ROOT / relative_path(pack["sourceManifest"])
    require(digest(source) == pack["sourceManifestSHA256"], "App manifest changed; review a new catalog snapshot explicitly")
    manifest = strict_json(source.read_bytes())
    require(manifest.get("formatVersion") == 1 and manifest.get("group") == pack["group"]
            and manifest.get("id") == pack["modelID"], "Model contract mismatch")
    details = manifest["source"]
    parameter_count = details.get("parameterCount", details.get("parameterCountConservative", details.get("parameterCountDeployed")))
    require(parameter_count == pack["parameterCount"], "Source parameter count changed")
    apple = manifest["apple"]
    require(apple["available"] is False and apple["assetPackID"] == pack["assetPackID"],
            "Only unavailable new packs may be staged")
    root = relative_path(apple["modelRootRelativePath"])
    contract_path = relative_path(apple["contractRelativePath"])
    require(root == "models/" + pack["modelID"] and contract_path == "contracts/" + pack["modelID"] + ".json",
            "Every pack requires its own model/contract namespace")
    pins = []
    for file in manifest["files"]:
        pin = {"relativePath": relative_path(file["path"]), "byteCount": file["byteCount"], "sha256": file["sha256"]}
        validate_pin(pin); pins.append(pin)
    names = [p["relativePath"].casefold() for p in pins]
    require(len(set(names)) == len(names) == pack["modelFileCount"], "Duplicate or missing model files")
    require(sum(p["byteCount"] for p in pins) == pack["modelByteCount"], "Model byte budget changed")
    for legal in pack["legalFiles"]:
        validate_pin(legal)
        require(legal["relativePath"].startswith("Licenses/" + pack["modelID"] + "/"), "Legal paths must be pack-specific")
        verify_file(ROOT / relative_path(legal["source"]), legal)
    # Extra packaging fields are ignored by the native Codable model contract;
    # its model pinIdentity remains exactly the App's supported field projection.
    contract = dict(manifest)
    contract["packaging"] = {"schemaVersion": 1, "sourceManifestSHA256": pack["sourceManifestSHA256"],
        "modelPinIdentitySHA256": model_pin_identity(manifest), "legalFiles": pack["legalFiles"],
        "publicationEnabled": False, "dataOnly": True, "neuralOrDeviceAcceptanceClaimed": False}
    files = [root + "/" + p["relativePath"] for p in pins]
    files += [p["relativePath"] for p in pack["legalFiles"]] + [contract_path]
    require(len(files) == len(set(path.casefold() for path in files)), "Duplicate archive paths")
    envelope = {"assetPackID": pack["assetPackID"], "platforms": ["iOS"],
                "downloadPolicy": {"onDemand": {}}, "fileSelectors": [{"file": path} for path in files]}
    spec = SPEC_ROOT / pack["group"]
    write_json(spec / "model-contract.json", contract)
    write_json(spec / "asset-manifest.json", envelope)
    return {"pack": pack, "manifest": manifest, "pins": pins, "contract": contract,
            "envelope": envelope, "spec": spec, "root": root, "contractPath": contract_path}


def verify_sources(spec, source):
    for pin in spec["pins"]:
        verify_file(source / pin["relativePath"], pin)
    for legal in spec["pack"]["legalFiles"]:
        verify_file(ROOT / legal["source"], legal)
    return {"group": spec["pack"]["group"], "modelID": spec["pack"]["modelID"],
            "sourceManifestSHA256": spec["pack"]["sourceManifestSHA256"],
            "modelPinIdentitySHA256": model_pin_identity(spec["manifest"]),
            "contractSHA256": digest(spec["spec"] / "model-contract.json"),
            "modelFileCount": len(spec["pins"]), "legalFileCount": len(spec["pack"]["legalFiles"]),
            "modelByteCount": spec["pack"]["modelByteCount"], "everySourceSHA256Verified": True}


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    run("/bin/cp", "-c", source, destination)


def verify_expanded(expanded, spec):
    outer = expanded / "Manifest.json"
    envelope = strict_json(outer.read_bytes())
    for key, value in spec["envelope"].items():
        require(envelope.get(key) == value, "Apple envelope mismatch: " + key)
    require(envelope.get("toolsVersion", {}).get("isBeta") is not True, "Beta ba-package output is not accepted")
    payload = expanded / "Contents"
    members = list(payload.rglob("*"))
    require(not any(path.is_symlink() for path in members), "Archive payload contains a symlink")
    actual = {path.relative_to(payload).as_posix() for path in members if path.is_file()}
    require(actual == {p["file"] for p in spec["envelope"]["fileSelectors"]}, "Archive contains extra/missing files")
    for pin in spec["pins"]:
        verify_file(payload / spec["root"] / pin["relativePath"], pin)
    for pin in spec["pack"]["legalFiles"]:
        verify_file(payload / pin["relativePath"], pin)
    contract = payload / spec["contractPath"]
    require(digest(contract) == digest(spec["spec"] / "model-contract.json"), "Contract bytes changed")
    return outer


def build(spec, source, output):
    checked = verify_sources(spec, source)
    group = spec["pack"]["group"]
    output = output / group
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (spec["pack"]["assetPackID"] + ".aar")
    manifest = output / "Manifest.json"
    receipt_path = output / "package-receipt.json"
    if receipt_path.exists():
        receipt = strict_json(receipt_path.read_bytes())
        require(receipt["contractSHA256"] == checked["contractSHA256"], "Existing output has a different pinned contract")
        for path, key in [(archive, "archive"), (manifest, "manifest")]:
            require(path.stat().st_size == receipt[key + "ByteCount"] and digest(path) == receipt[key + "SHA256"],
                    "Receipted output changed")
        emit("retained_verified_pack", group=group, archiveSHA256=receipt["archiveSHA256"])
        return receipt
    require(not archive.exists() and not manifest.exists(), "Unreceipted artifacts exist; preserve them for review")
    with tempfile.TemporaryDirectory(prefix=".staging-", dir=output) as temporary:
        work = Path(temporary); payload = work / "payload"
        for pin in spec["pins"]:
            target = payload / spec["root"] / pin["relativePath"]
            clone(source / pin["relativePath"], target); verify_file(target, pin)
        for pin in spec["pack"]["legalFiles"]:
            target = payload / pin["relativePath"]
            clone(ROOT / pin["source"], target); verify_file(target, pin)
        clone(spec["spec"] / "model-contract.json", payload / spec["contractPath"])
        run("xcrun", "ba-package", "evaluate", spec["spec"] / "asset-manifest.json", cwd=payload)
        emit("native_payload_staged", **checked)
        staged_archive = work / archive.name
        run("xcrun", "ba-package", "package", spec["spec"] / "asset-manifest.json",
            "--output-path", staged_archive, cwd=payload)
        emit("native_archive_created", group=group)
        expanded = work / "roundtrip"; expanded.mkdir()
        run("xcrun", "aa", "extract", "-i", staged_archive, "-d", expanded)
        outer = verify_expanded(expanded, spec)
        # Recheck control files after packaging; model bytes were re-read from
        # the archive and compared to fixed per-file pins above.
        require(digest(ROOT / spec["pack"]["sourceManifest"]) == checked["sourceManifestSHA256"], "App manifest changed during packaging")
        record = {"schemaVersion": 1, "appID": "6831042755", "bundleID": "com.kaisun.voxamber",
            "assetPackID": spec["pack"]["assetPackID"], **checked,
            "builtAtUTC": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "payloadFileCount": len(spec["envelope"]["fileSelectors"]), "platforms": ["iOS"],
            "downloadPolicy": "onDemand", "dataOnlyPayloadVerified": True,
            "appleArchiveRoundtripVerified": True, "publicationEnabled": False, "uploaded": False,
            "neuralOrDeviceAcceptanceClaimed": False, "packagingTool": run("xcrun", "ba-package", "--version").strip()}
        for path, key in [(staged_archive, "archive"), (outer, "manifest")]:
            record[key + "ByteCount"] = path.stat().st_size
            record[key + "SHA256"] = digest(path)
        os.link(staged_archive, archive); os.link(outer, manifest)
        write_json(receipt_path, record)
        write_json(spec["spec"] / "package-receipt.json", record)
        emit("native_pack_roundtrip_verified", group=group, archiveByteCount=record["archiveByteCount"],
             archiveSHA256=record["archiveSHA256"], manifestSHA256=record["manifestSHA256"])
        return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("specifications", "preflight", "package"))
    parser.add_argument("--group", choices=("all", "intent", "image", "shape"), default="all")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    for group in sorted(GROUPS):
        parser.add_argument("--source-" + group, type=Path)
    args = parser.parse_args()
    output = no_symlink_ancestors(args.output)
    require(output.is_relative_to(ROOT / "Apple/.build"), "Staging/output must stay under ignored Apple/.build")
    catalog = load_catalog(); results = []
    for pack in catalog["packs"]:
        if args.group not in ("all", pack["group"]):
            continue
        spec = specifications(pack)
        source = no_symlink_ancestors(getattr(args, "source_" + pack["group"]) or ROOT / pack["sourceRoot"])
        if args.mode == "specifications":
            emit("specifications_ready", group=pack["group"], contractSHA256=digest(spec["spec"] / "model-contract.json"))
        elif args.mode == "preflight":
            record = verify_sources(spec, source); results.append(record); emit("source_preflight_passed", **record)
        else:
            results.append(build(spec, source, output))
    if results:
        receipt = {"schemaVersion": 1, "mode": args.mode, "appID": catalog["appID"], "bundleID": catalog["bundleID"],
            "checkedAtUTC": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "catalogSHA256": digest(CATALOG), "parameterBudgetMaximum": catalog["parameterBudgetMaximum"],
            "deployedParameterCountConservative": catalog["deployedParameterCountConservative"],
            "publicationEnabled": False, "uploaded": False, "neuralOrDeviceAcceptanceClaimed": False,
            "officialSources": OFFICIAL_SOURCES, "packs": results}
        write_json(output / (args.mode + "-" + args.group + "-receipt.json"), receipt)
        write_json(SPEC_ROOT / (args.mode + "-" + args.group + "-receipt.json"), receipt)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit("PACK_PREFLIGHT_FAILED: " + str(error))
