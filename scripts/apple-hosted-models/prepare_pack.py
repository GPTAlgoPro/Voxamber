#!/usr/bin/env python3
"""Create and round-trip verify Voxamber's data-only Apple-hosted Qwen model pack.

This development-host tool never enters the application payload. Model data is
packaged with Apple's native ba-package / AppleArchive tools, not an interpreter.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MODEL_ID = "qwen3.5-4b-mlx-int4"
ASSET_ID = "Voxamber-Qwen35-4B-INT4"
DISPLAY_NAME = "Voxamber - Qwen3.5 4B INT4"
APP_ID = "6831042755"
BUNDLE_ID = "com.kaisun.voxamber"
MODEL_ROOT = "models/" + MODEL_ID
SPEC_ROOT = ROOT / "Apple/AssetPacks/Qwen35-4B-INT4"
MODEL_MANIFEST = ROOT / "Apple/ThreeLiveStudio/Resources/LanguageModel.json"
LEGAL_ROOT = ROOT / "Apple/ThreeLiveStudio/Resources/Licenses"
LEGAL_NAMES = ("MLX-Swift.txt", "MLX-Swift-LM.txt", "Qwen-Model.txt", "Swift-Transformers.txt")
MODEL_NAMES = frozenset(("chat_template.jinja", "config.json", "model.safetensors",
    "model.safetensors.index.json", "preprocessor_config.json", "processor_config.json",
    "tokenizer.json", "tokenizer_config.json", "video_preprocessor_config.json", "vocab.json"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def file_identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def verify_file(path, pin):
    require(not path.is_symlink(), "Pinned model/legal file must not be a symlink")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and not before.st_mode & 0o111,
                "Asset payload must contain non-executable regular files")
        require(before.st_size == pin["byteCount"], "Pinned byte count differs: " + pin["relativePath"])
        h = hashlib.sha256()
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(chunk)
        require(file_identity(before) == file_identity(os.fstat(stream.fileno())), "Source changed while hashing")
    require(h.hexdigest() == pin["sha256"], "Pinned SHA-256 differs: " + pin["relativePath"])


def run(*arguments, cwd=None):
    result = subprocess.run([str(a) for a in arguments], cwd=cwd, capture_output=True, text=True)
    require(result.returncode == 0, "Native packaging command failed: " + str(arguments[0]))
    return result.stdout


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    run("/bin/cp", "-c", source, destination)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if path.exists() and path.read_text() == text:
        return
    path.write_text(text)


def specifications():
    manifest = json.loads(MODEL_MANIFEST.read_text())
    require(manifest.get("id") == MODEL_ID, "This pack is pinned to the selected Qwen 4B model")
    files = manifest.get("files", [])
    require(len(files) == 10 and {f["path"] for f in files} == MODEL_NAMES, "Expected exactly ten pinned model files")
    pins = []
    for item in files:
        require(re.fullmatch("[0-9a-f]{64}", item["sha256"]) is not None, "Invalid model digest")
        require(type(item["byteCount"]) is int and item["byteCount"] > 0, "Invalid model file size")
        pins.append({"relativePath": item["path"], "byteCount": item["byteCount"], "sha256": item["sha256"]})
    legal = []
    for name in LEGAL_NAMES:
        path = LEGAL_ROOT / name
        require(path.is_file() and not path.is_symlink(), "Required license file is unavailable")
        legal.append({"relativePath": "Licenses/" + name, "byteCount": path.stat().st_size, "sha256": digest(path)})
    contract = {"schemaVersion": 1, "assetPackID": ASSET_ID, "modelID": MODEL_ID,
        "modelRootRelativePath": MODEL_ROOT, "runtime": "Swift MLX / Metal",
        "quantizationBits": 4, "modelManifestSHA256": digest(MODEL_MANIFEST),
        "sourceRevisions": {"ModelScope": "ab9c7a42fd31095a40634b3362317779dee9e7fa",
            "HuggingFace": "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c"},
        "files": pins, "legalFiles": legal}
    file_paths = [MODEL_ROOT + "/" + item["relativePath"] for item in pins]
    file_paths += [item["relativePath"] for item in legal] + ["model-contract.json"]
    apple = {"assetPackID": ASSET_ID, "platforms": ["iOS"], "downloadPolicy": {"onDemand": {}},
        "fileSelectors": [{"file": path} for path in file_paths]}
    catalog = {"schemaVersion": 1, "appID": APP_ID, "bundleID": BUNDLE_ID,
        "packs": [{"key": "qwen35_4b", "displayName": DISPLAY_NAME, "descriptor": contract}]}
    write_json(SPEC_ROOT / "model-contract.json", contract)
    write_json(SPEC_ROOT / "asset-manifest.json", apple)
    write_json(ROOT / "Apple/AssetPacks/catalog.json", catalog)
    return contract, apple


def validate_roundtrip(archive, expanded, contract, expected):
    expanded.mkdir()
    run("xcrun", "aa", "extract", "-i", archive, "-d", expanded)
    outer_path = expanded / "Manifest.json"
    outer = json.loads(outer_path.read_text())
    for key in ("assetPackID", "platforms", "downloadPolicy", "fileSelectors"):
        require(outer.get(key) == expected[key], "Apple envelope field differs: " + key)
    require(outer.get("toolsVersion", {}).get("isBeta") is not True, "Apple pack was built by beta packaging tools")
    contents = expanded / "Contents"
    members = list(contents.rglob("*"))
    require(not any(p.is_symlink() for p in members), "Apple pack contains a symlink")
    actual = {str(p.relative_to(contents)) for p in members if p.is_file()}
    require(actual == {item["file"] for item in expected["fileSelectors"]}, "Apple pack contains extra or missing payload files")
    for item in contract["files"]:
        verify_file(contents / MODEL_ROOT / item["relativePath"], item)
    for item in contract["legalFiles"]:
        verify_file(contents / item["relativePath"], item)
    require(json.loads((contents / "model-contract.json").read_text()) == contract, "Archive contract changed")
    return outer_path


def build(source, output):
    contract, apple = specifications()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (DISPLAY_NAME + ".aar")
    outer_path = output / "Manifest.json"
    receipt_path = output / "package-receipt.json"
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        require(receipt["contractSHA256"] == digest(SPEC_ROOT / "model-contract.json"), "Existing pack belongs to a different model/legal contract")
        for path, prefix in ((archive, "archive"), (outer_path, "manifest")):
            require(path.is_file() and path.stat().st_size == receipt[prefix + "ByteCount"]
                    and digest(path) == receipt[prefix + "SHA256"], "Existing packaged artifact changed")
        print(json.dumps({"event": "retained_verified_pack", "receipt": str(receipt_path)}), flush=True)
        return
    require(not archive.exists() and not outer_path.exists(), "Unreceipted output exists; retain it for inspection")
    with tempfile.TemporaryDirectory(prefix=".native-pack-", dir=output) as directory:
        work = Path(directory)
        payload = work / "payload"
        for item in contract["files"]:
            original = source / item["relativePath"]
            verify_file(original, item)
            clone(original, payload / MODEL_ROOT / item["relativePath"])
        for item in contract["legalFiles"]:
            original = LEGAL_ROOT / Path(item["relativePath"]).name
            verify_file(original, item)
            clone(original, payload / item["relativePath"])
        clone(SPEC_ROOT / "model-contract.json", payload / "model-contract.json")
        print(json.dumps({"event": "pinned_payload_verified", "modelFiles": 10, "licenseFiles": 4,
            "modelBytes": sum(item["byteCount"] for item in contract["files"])}), flush=True)
        run("xcrun", "ba-package", "evaluate", SPEC_ROOT / "asset-manifest.json", cwd=payload)
        staged_archive = work / archive.name
        run("xcrun", "ba-package", "package", SPEC_ROOT / "asset-manifest.json", "--output-path", staged_archive, cwd=payload)
        outer = validate_roundtrip(staged_archive, work / "roundtrip", contract, apple)
        record = {"schemaVersion": 1, "appID": APP_ID, "bundleID": BUNDLE_ID, "assetPackID": ASSET_ID,
            "platforms": ["iOS"], "builtAtUTC": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "contractSHA256": digest(SPEC_ROOT / "model-contract.json"), "payloadFileCount": 15,
            "modelByteCount": sum(item["byteCount"] for item in contract["files"]),
            "dataOnlyPayloadVerified": True, "appleArchiveRoundtripVerified": True,
            "packagingTool": run("xcrun", "ba-package", "--version").strip()}
        for path, prefix in ((staged_archive, "archive"), (outer, "manifest")):
            record[prefix + "ByteCount"] = path.stat().st_size
            record[prefix + "SHA256"] = digest(path)
        os.link(staged_archive, archive)
        os.link(outer, outer_path)
        write_json(receipt_path, record)
        print(json.dumps({"event": "native_pack_verified", **record}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "Apple/.build/Models" / MODEL_ID)
    parser.add_argument("--output", type=Path, default=ROOT / "Apple/.build/apple-hosted-qwen35")
    parser.add_argument("--specifications-only", action="store_true")
    args = parser.parse_args()
    if args.specifications_only:
        specifications()
    else:
        build(args.source.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
