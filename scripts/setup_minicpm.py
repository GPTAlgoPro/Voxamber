#!/usr/bin/env python3
"""Reproducible, credential-free native inference setup. Never changes another checkout."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tarfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / "Apple/.build"
ENGINE_REV = "e0eca9d8f57ac8f5a5ad6191a8007b93436c1e71"
ENGINE = BUILD / f"llama.cpp-omni-{ENGINE_REV}"
PACKAGE = ROOT / "Apple/Packages/MiniCPMNative"

def run(*args: str, cwd: pathlib.Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)

def digest(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def download(url: str, destination: pathlib.Path, expected_size: int | None = None,
             sha256: str | None = None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and (expected_size is None or destination.stat().st_size == expected_size):
        if sha256 is None or digest(destination) == sha256:
            print(f"Verified {destination.name}", flush=True)
            return
    temporary = destination.with_suffix(destination.suffix + ".partial")
    for attempt in range(4):
        offset = temporary.stat().st_size if temporary.exists() else 0
        if expected_size is not None and offset == expected_size:
            if sha256 is None or digest(temporary) == sha256:
                temporary.replace(destination)
                return
            temporary.unlink()
            offset = 0
        headers = {"User-Agent": "MojieNative/1.0"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=90) as source:
                resumed = offset > 0 and source.status == 206
                with temporary.open("ab" if resumed else "wb") as output:
                    received = offset if resumed else 0
                    reported = received
                    while block := source.read(4 * 1024 * 1024):
                        output.write(block)
                        received += len(block)
                        if received - reported >= 64 * 1024 * 1024:
                            print(f"{destination.name}: {received / 1e6:.0f} MB", flush=True)
                            reported = received
            break
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == 3:
                raise
            time.sleep(min(2 ** attempt, 8))
    if expected_size is not None and temporary.stat().st_size != expected_size:
        raise RuntimeError(f"Wrong byte count: {destination.name}")
    if sha256 and digest(temporary) != sha256:
        raise RuntimeError(f"SHA-256 mismatch: {destination.name}")
    temporary.replace(destination)
    print(f"Verified {destination.name}", flush=True)

def source() -> None:
    if (ENGINE / "include/llama.h").exists():
        return
    archive = BUILD / f"llama-{ENGINE_REV}.tar.gz"
    download(f"https://api.github.com/repos/tc-mb/llama.cpp-omni/tarball/{ENGINE_REV}", archive)
    ENGINE.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        prefix = members[0].name.split("/")[0] + "/"
        for member in members:
            if not member.name.startswith(prefix):
                continue
            relative = pathlib.PurePosixPath(member.name[len(prefix):])
            if not relative.parts or ".." in relative.parts or relative.is_absolute():
                continue
            if member.issym() or member.islnk():
                continue
            member.name = str(relative)
            source.extract(member, ENGINE, filter="data")
    (ENGINE / "PINNED_REVISION").write_text(ENGINE_REV + "\n")

def build_framework(include_macos: bool) -> None:
    source()
    args = []
    slices = [("iphoneos", "iOS", "ios-arm64"),
              ("iphonesimulator", "iOS", "ios-arm64-simulator")]
    if include_macos:
        slices.append(("macosx", "Darwin", "macos-arm64"))
    for sdk, system, name in slices:
        output = BUILD / "native" / name
        output.mkdir(parents=True, exist_ok=True)
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        run("cmake", "-S", str(ENGINE), "-B", str(output), "-G", "Xcode",
            f"-DCMAKE_SYSTEM_NAME={system}", f"-DCMAKE_OSX_SYSROOT={sdk_path}",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + ("14.0" if sdk == "macosx" else "26.0"),
            "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO", "-DBUILD_SHARED_LIBS=OFF",
            "-DLLAMA_BUILD_COMMON=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF", "-DLLAMA_BUILD_TOOLS=OFF",
            "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_OPENSSL=OFF",
            "-DLLAMA_CURL=OFF", "-DGGML_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON",
            "-DGGML_BLAS=ON", "-DGGML_NATIVE=OFF", "-DGGML_OPENMP=OFF")
        run("cmake", "--build", str(output), "--config", "Release", "--target", "llama",
            "-j", str(min(8, os.cpu_count() or 4)), "--", "-quiet")
        framework = output / "llama.framework"
        (framework / "Headers").mkdir(parents=True, exist_ok=True)
        (framework / "Modules").mkdir(exist_ok=True)
        libraries = sorted(str(p) for p in output.rglob("*.a") if "/Release" in str(p))
        if not libraries:
            raise RuntimeError(f"No static libraries for {sdk}")
        run("xcrun", "libtool", "-static", "-o", str(framework / "llama"), *libraries)
        for p in [ENGINE / "include/llama.h", *(ENGINE / "ggml/include").glob("*.h")]:
            shutil.copy2(p, framework / "Headers" / p.name)
        (framework / "Modules/module.modulemap").write_text('''framework module llama {
 umbrella header "llama.h"
 link "c++"
 link framework "Accelerate"
 link framework "Metal"
 link framework "Foundation"
 export *
}
''')
        metadata = {"CFBundleIdentifier": "cn.mojie.native.llama", "CFBundleName": "llama",
                    "CFBundleExecutable": "llama", "CFBundlePackageType": "FMWK",
                    "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                    "MinimumOSVersion": "14.0" if sdk == "macosx" else "26.0",
                    "CFBundleSupportedPlatforms": [{"iphoneos": "iPhoneOS", "iphonesimulator": "iPhoneSimulator", "macosx": "MacOSX"}[sdk]]}
        (framework / "Info.plist").write_bytes(plistlib.dumps(metadata))
        args += ["-framework", str(framework)]
    destination = PACKAGE / "Frameworks/llama.xcframework"
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    run("xcodebuild", "-create-xcframework", *args, "-output", str(destination))
    (PACKAGE / "Frameworks/SOURCE_REVISION").write_text(ENGINE_REV + "\n")
    licenses = PACKAGE / "Licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copy2(ENGINE / "LICENSE", licenses / "llama.cpp-MIT.txt")

def models(include_vision: bool, model_id: str | None, catalog_path: pathlib.Path | None) -> None:
    catalog = json.loads((catalog_path or ROOT / "Apple/Resources/ModelCatalog.json").read_text())
    for model in catalog["models"]:
        if model["id"] != (model_id or catalog["defaultModelID"]):
            continue
        for file in model["files"]:
            if file["required"] or include_vision:
                # Mirrors are included only after their complete file hashes match the pinned source.
                download(file.get("mirrorURL", file["url"]), BUILD / "Models" / model["id"] / file["filename"], file["bytes"], file["sha256"])

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", action="store_true")
    parser.add_argument("--models", action="store_true")
    parser.add_argument("--model-id", help="Defaults to the app catalogue's selected model")
    parser.add_argument("--catalog", type=pathlib.Path, help="Optional development-only comparison catalogue")
    parser.add_argument("--vision", action="store_true", help="Also download optional f16 projector; current API is text-only")
    parser.add_argument("--macos", action="store_true", help="Include a macOS arm64 slice for native inference acceptance")
    options = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    if not options.framework and not options.models:
        parser.error("Select --framework and/or --models")
    if options.framework:
        build_framework(options.macos)
    if options.models:
        models(options.vision, options.model_id, options.catalog)

if __name__ == "__main__":
    main()
