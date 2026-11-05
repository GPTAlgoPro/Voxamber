#!/usr/bin/env python3
"""Upload the pinned Voxamber Qwen AppleArchive; default is read-only preflight.

Contract: Apple/AssetPacks/catalog.json. Apple OpenAPI:
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
No review submission, release, deletion, or replacement is performed.
"""
import argparse
import base64
import contextlib
import concurrent.futures
from dataclasses import dataclass
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Apple/AssetPacks/catalog.json"
APP_ID = "6831042755"
BUNDLE_ID = "com.kaisun.voxamber"
PLATFORM = "IOS"
PACK_KEYS = {"qwen35_4b"}
ID_PATTERN = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", re.ASCII)


class UploadError(Exception):
    """Messages must never contain response bodies, signed URLs or headers."""


class APIError(UploadError):
    def __init__(self, method, status):
        super().__init__(f"ASC {method} returned HTTP {status}")
        self.status = status


class PartError(UploadError):
    def __init__(self, status):
        super().__init__(f"Apple part upload returned HTTP {status}")
        self.status = status


def require(condition, message):
    if not condition:
        raise UploadError(message)


def emit(event, **fields):
    print(json.dumps({"event": event, "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      **fields}, sort_keys=True), flush=True)


def stat_key(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@dataclass(frozen=True)
class Artifact:
    path: Path
    file_name: str
    size: int
    sha256: str
    md5: str
    signature: tuple

    @classmethod
    def inspect(cls, path, expected_sha256, file_name=None):
        path = Path(path).absolute()
        require(re.fullmatch(r"[0-9a-f]{64}", expected_sha256), "An approved SHA-256 is required")
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                require(stat.S_ISREG(before.st_mode) and before.st_size > 0, "Artifact must be a regular nonempty file")
                sha, md5 = hashlib.sha256(), hashlib.md5()
                for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
                    sha.update(block)
                    md5.update(block)
                require(stat_key(before) == stat_key(os.fstat(stream.fileno())), "Artifact changed while hashing")
        except OSError:
            raise UploadError("Unable to read regular artifact") from None
        require(sha.hexdigest() == expected_sha256, "Artifact differs from approved SHA-256")
        return cls(path, file_name or path.name, before.st_size, sha.hexdigest(), md5.hexdigest(), stat_key(before))

    def unchanged(self):
        require(stat_key(self.path.lstat()) == self.signature, "Artifact changed after preflight")

    def identity(self):
        return {"file_name": self.file_name, "size": self.size, "sha256": self.sha256, "md5": self.md5}


def load_catalog(path=CATALOG):
    raw = path.read_bytes()
    catalog = json.loads(raw)
    packs = catalog.get("packs", [])
    require(catalog.get("schemaVersion") == 1 and len(packs) == 1
            and catalog.get("appID") == APP_ID and catalog.get("bundleID") == BUNDLE_ID,
            "Expected the exact Voxamber-owned model catalog")
    require({p["key"] for p in packs} == PACK_KEYS, "Unexpected pack keys")
    result = {p["descriptor"]["assetPackID"]: p for p in packs}
    require(len(result) == 1 and set(result) == {"Voxamber-Qwen35-4B-INT4"}
            and all(ID_PATTERN.fullmatch(key) for key in result),
            "Asset IDs must use ASCII letters, digits and internal hyphens")
    return result, hashlib.sha256(raw).hexdigest()


def validate_manifest(manifest, pack):
    descriptor = pack["descriptor"]
    require(manifest.get("assetPackID") == descriptor["assetPackID"], "Manifest asset ID differs from App catalog")
    require(manifest.get("platforms") == ["iOS"], "Voxamber manifest must select iOS only")
    require(manifest.get("downloadPolicy") == {"onDemand": {}}, "The model pack must be on demand")
    require(manifest.get("toolsVersion", {}).get("isBeta") is not True, "Beta packaging is not allowed")
    expected = {descriptor["modelRootRelativePath"] + "/" + f["relativePath"] for f in descriptor["files"]}
    expected.update(f["relativePath"] for f in descriptor["legalFiles"])
    expected.add("model-contract.json")
    selectors = [entry["file"] for entry in manifest.get("fileSelectors", [])]
    require(len(selectors) == len(expected) and set(selectors) == expected,
            "Manifest file selectors differ from App-owned models and legal files")


def verify_outer_manifest(archive, manifest):
    """Read only Apple's outer manifest, not the multi-GB payload extraction."""
    with tempfile.TemporaryDirectory(prefix="VoxamberUploadManifest-") as temporary:
        result = subprocess.run(["xcrun", "aa", "extract", "-i", str(archive.path), "-d", temporary,
                                 "-include-regex", "^Manifest[.]json$", "-include-type", "f", "-t", "2"],
                                capture_output=True)
        require(result.returncode == 0, "AppleArchive outer-manifest extraction failed")
        extracted = Path(temporary) / "Manifest.json"
        require(extracted.is_file() and not extracted.is_symlink(), "Archive has no regular outer Manifest.json")
        require(extracted.stat().st_size == manifest.size, "Archive outer-manifest size differs from approved sidecar")
        require(hashlib.sha256(extracted.read_bytes()).hexdigest() == manifest.sha256,
                "Archive outer manifest differs from approved sidecar")
    archive.unchanged()
    manifest.unchanged()


def reuse_verified_preflight(state_path, archive_path, approved_sha, manifest, identifier, catalog_hash):
    """Reuse only a prior complete preflight of unchanged regular file inodes.

    The private resume state records device/inode/size/mtime/ctime after hashing
    and AppleArchive validation. Older state without those stamps is rechecked.
    """
    path = Path(state_path)
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 4 * 1024 * 1024:
        return None
    data = json.loads(path.read_text())
    saved, identity = data.get("validated_preflight"), data.get("identity", {})
    if not saved or not saved.get("outer_manifest_verified"):
        return None
    require(identity.get("app_id") == APP_ID and identity.get("bundle_id") == BUNDLE_ID
            and identity.get("platform") == PLATFORM and identity.get("asset_pack_id") == identifier
            and identity.get("catalog_sha256") == catalog_hash, "Cached preflight belongs to different App/catalog")
    artifact = identity["artifacts"]["ASSET"]
    require(artifact["sha256"] == approved_sha and identity["artifacts"]["MANIFEST"] == manifest.identity(),
            "Cached preflight differs from approved hashes")
    archive_path = Path(archive_path).absolute()
    info = archive_path.lstat()
    if not stat.S_ISREG(info.st_mode) or list(stat_key(info)) != saved.get("archive_stat") or list(manifest.signature) != saved.get("manifest_stat"):
        return None
    require(artifact["file_name"] == archive_path.name and artifact["size"] == info.st_size,
            "Cached archive identity changed")
    return Artifact(archive_path, artifact["file_name"], artifact["size"], artifact["sha256"],
                    artifact["md5"], stat_key(info))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def der_signature(raw):
    def read_length(pos):
        count = raw[pos]
        pos += 1
        if count & 128:
            size = count & 127
            require(0 < size <= 2, "Invalid signing response")
            count = int.from_bytes(raw[pos:pos + size], "big")
            pos += size
        return count, pos
    require(raw and raw[0] == 0x30, "Invalid signing response")
    size, pos = read_length(1)
    require(pos + size == len(raw), "Invalid signing response")
    result = b""
    for _ in range(2):
        require(raw[pos] == 2, "Invalid signing response")
        size, pos = read_length(pos + 1)
        value = int.from_bytes(raw[pos:pos + size], "big")
        require(0 < value < 2**256, "Signing key is not P-256")
        result += value.to_bytes(32, "big")
        pos += size
    require(pos == len(raw), "Invalid signing response")
    return result


class API:
    def __init__(self, key_id, issuer, key_path, allow_upload=False):
        self.key_id, self.issuer = key_id, issuer
        self.key_path = Path(key_path).resolve()
        require(not self.key_path.is_relative_to(ROOT), "Private key must remain outside the repository")
        require(self.key_path.is_file(), "Private key file is unavailable")
        self.allow_upload = allow_upload
        self.opener = urllib.request.build_opener(NoRedirect())

    def token(self):
        encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=").decode()
        now = int(time.time())
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        claims = {"iss": self.issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
        body = (encode(json.dumps(header).encode()) + "." + encode(json.dumps(claims).encode())).encode()
        result = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", str(self.key_path)],
                                input=body, capture_output=True)
        require(result.returncode == 0, "JWT signing failed")
        return body.decode() + "." + encode(der_signature(result.stdout))

    def request(self, method, path, payload=None):
        require(method in {"GET", "POST", "PATCH"}, "Unsupported API operation")
        require(method == "GET" or self.allow_upload, "Preflight prohibits remote mutations")
        require(path.startswith("/v1/") and "#" not in path, "Invalid API path")
        request = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
            data=None if payload is None else json.dumps(payload).encode(), method=method,
            headers={"Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Raw server bodies and exception strings can contain URLs/tokens.
            raise APIError(method, error.code) from None
        except (OSError, ValueError, http.client.HTTPException):
            raise UploadError(f"ASC {method} transport failed; resume without discarding state") from None

    def rows(self, path):
        rows = []
        while path:
            result = self.request("GET", path)
            rows.extend(result["data"])
            next_url = result.get("links", {}).get("next")
            if not next_url:
                break
            parsed = urllib.parse.urlsplit(next_url)
            require(parsed.scheme == "https" and parsed.netloc == "api.appstoreconnect.apple.com",
                    "Unexpected API pagination host")
            path = parsed.path + ("?" + parsed.query if parsed.query else "")
        return rows

    def verify_target(self):
        app = self.request("GET", f"/v1/apps/{APP_ID}")["data"]
        require(app["id"] == APP_ID and app["attributes"]["bundleId"] == BUNDLE_ID,
                "App identity differs from the required Voxamber record")
        versions = self.rows(f"/v1/apps/{APP_ID}/appStoreVersions?filter%5Bplatform%5D=IOS&limit=200")
        require(any(v["attributes"].get("platform") == PLATFORM for v in versions), "App has no iOS platform")


def put_part(artifact, operation):
    parsed = urllib.parse.urlsplit(operation["url"])
    require(parsed.scheme == "https" and parsed.hostname and parsed.hostname.endswith(".apple.com")
            and not parsed.username and not parsed.password and parsed.port in (None, 443),
            "Upload destination is not an Apple HTTPS host")
    require(operation["method"] == "PUT", "Unexpected upload method")
    headers = {entry["name"]: entry["value"] for entry in operation.get("requestHeaders", [])}
    require(all(isinstance(k, str) and isinstance(v, str) and not any(c in k + v for c in "\r\n")
                for k, v in headers.items()), "Invalid upload headers")
    require(not any(k.lower() in {"authorization", "host", "transfer-encoding"} for k in headers),
            "Unexpected upload transport headers")
    length, offset = operation["length"], operation["offset"]
    require(0 <= offset < artifact.size and 0 < length <= artifact.size - offset, "Invalid upload byte range")
    for key in list(headers):
        if key.lower() == "content-length":
            require(headers.pop(key) == str(length), "Incorrect upload content length")
    headers["Content-Length"] = str(length)
    connection = http.client.HTTPSConnection(parsed.hostname, timeout=120)
    try:
        artifact.unchanged()
        with os.fdopen(os.open(artifact.path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
            require(stat_key(os.fstat(stream.fileno())) == artifact.signature, "Artifact identity changed")
            stream.seek(offset)
            connection.putrequest("PUT", parsed.path + ("?" + parsed.query if parsed.query else ""))
            for key, value in headers.items():
                connection.putheader(key, value)
            connection.endheaders()
            remaining = length
            while remaining:
                block = stream.read(min(1024 * 1024, remaining))
                require(bool(block), "Artifact ended before upload range")
                connection.send(block)
                remaining -= len(block)
            response = connection.getresponse()
            if not 200 <= response.status < 300:
                raise PartError(response.status)
            response.read(64 * 1024)
        artifact.unchanged()
    except (OSError, http.client.HTTPException):
        raise UploadError("Apple part transport failed") from None
    finally:
        connection.close()


def part_ranges(operations, completed, size):
    ranges = {(op["offset"], op["length"]) for op in operations}
    require(len(ranges) == len(operations), "Duplicate upload ranges")
    ranges.update(tuple(pair) for pair in completed)
    position = 0
    for offset, length in sorted(ranges):
        require(type(offset) is int and type(length) is int and offset == position and length > 0,
                "Upload ranges have gaps or overlaps")
        position += length
    require(position == size, "Upload ranges do not cover the approved file")


class ResumeState:
    def __init__(self, path, identity):
        self.path = Path(path)
        require(not self.path.is_symlink(), "Resume state may not be a symlink")
        if self.path.exists():
            require(self.path.stat().st_size <= 4 * 1024 * 1024, "Resume state is too large")
            self.data = json.loads(self.path.read_text())
            require(self.data.get("schema_version") == 1 and self.data.get("identity") == identity,
                    "Resume state belongs to different approved artifacts/catalog")
        else:
            self.data = {"schema_version": 1, "identity": identity, "files": {}}

    def save(self):
        # Construct state ourselves: never store API responses or operation URLs.
        permitted = {"schema_version", "identity", "files", "asset_id", "version_id",
                     "version_creation_pending", "baseline_version_ids", "status", "version", "validated_preflight"}
        require(set(self.data) <= permitted, "Unexpected fields in resume state")
        for record in self.data["files"].values():
            require(set(record) <= {"id", "completed_parts", "complete"}, "Unsafe resume file fields")
            require(all(isinstance(pair, list) and len(pair) == 2
                        and all(type(n) is int for n in pair) and pair[0] >= 0 and pair[1] > 0
                        for pair in record.get("completed_parts", [])), "Invalid saved upload ranges")
        encoded = json.dumps(self.data)
        require(not any(secret in encoded for secret in ["https://", "http://", "Bearer ", "PRIVATE KEY",
                                                       "uploadOperations", "requestHeaders", "assetToken"]),
                "Resume state contains unsafe transport data")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=self.path.name + ".", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(self.data, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


class Uploader:
    def __init__(self, api, state, artifacts, *, send_part=put_part, poll_seconds=15,
                 timeout_seconds=3600, sleep=time.sleep, parallel_parts=1, parallel_control=None):
        self.api, self.state, self.artifacts = api, state, artifacts
        self.send_part, self.poll_seconds, self.timeout_seconds, self.sleep = send_part, poll_seconds, timeout_seconds, sleep
        require(1 <= parallel_parts <= 8, "Parallel part limit must be between 1 and 8")
        self.parallel_parts = parallel_parts
        self.parallel_control = Path(parallel_control) if parallel_control else None
        self.parallel_lock = threading.Lock()
        self.parallel_cap = 8

    def part_limit(self):
        target = self.parallel_parts
        if self.parallel_control and self.parallel_control.exists():
            require(self.parallel_control.stat().st_size <= 4096, "Parallel control is too large")
            try:
                control = json.loads(self.parallel_control.read_text())
                requested = control["parallel_parts"]
                if type(requested) is int and 1 <= requested <= 8:
                    target = requested
            except (OSError, ValueError, KeyError):
                pass  # A partial operator edit must not terminate an active upload.
        with self.parallel_lock:
            return min(target, self.parallel_cap)

    def reduce_part_limit(self, status):
        if status == 429 or (status is not None and status >= 500):
            current = self.part_limit()
            with self.parallel_lock:
                self.parallel_cap = min(self.parallel_cap, max(1, current // 2))
                cap = self.parallel_cap
            emit("parallel_backoff", status=status, parallel_cap=cap)

    def versions(self):
        return self.api.rows(f"/v1/backgroundAssets/{self.state.data['asset_id']}/versions?limit=200")

    def ensure_version(self):
        data = self.state.data
        identifier = data["identity"]["asset_pack_id"]
        matches = [row for row in self.api.rows(f"/v1/apps/{APP_ID}/backgroundAssets?limit=200")
                   if row["attributes"].get("assetPackIdentifier") == identifier]
        require(len(matches) <= 1, "Ambiguous server asset identity")
        if not matches:
            require(not data.get("asset_id"), "Saved asset is absent from required App")
            matches = [self.api.request("POST", "/v1/backgroundAssets", {"data": {
                "type": "backgroundAssets", "attributes": {"assetPackIdentifier": identifier},
                "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})["data"]]
        require(not data.get("asset_id") or data["asset_id"] == matches[0]["id"], "Saved asset belongs elsewhere")
        data["asset_id"] = matches[0]["id"]
        self.state.save()
        versions = self.versions()
        if data.get("version_id"):
            require(any(v["id"] == data["version_id"] for v in versions), "Saved version is absent from asset")
            return
        if data.get("version_creation_pending"):
            candidates = [v for v in versions if v["id"] not in data["baseline_version_ids"]]
            require(len(candidates) == 1, "Version creation was interrupted; no unambiguous new version yet. Keep state and retry")
            data["version_id"] = candidates[0]["id"]
        else:
            data["baseline_version_ids"] = [v["id"] for v in versions]
            data["version_creation_pending"] = True
            self.state.save()  # An uncertain POST must never blindly create another version.
            try:
                result = self.api.request("POST", "/v1/backgroundAssetVersions", {"data": {
                    "type": "backgroundAssetVersions", "relationships": {"backgroundAsset": {
                        "data": {"type": "backgroundAssets", "id": data["asset_id"]}}}}})
            except APIError as error:
                if error.status < 500:
                    data["version_creation_pending"] = False
                    self.state.save()
                raise
            data["version_id"] = result["data"]["id"]
        data["version_creation_pending"] = False
        self.state.save()

    def version(self):
        return self.api.request("GET", f"/v1/backgroundAssetVersions/{self.state.data['version_id']}")["data"]

    def ensure_file(self, kind):
        artifact = self.artifacts[kind]
        rows = self.api.rows(f"/v1/backgroundAssetVersions/{self.state.data['version_id']}/backgroundAssetUploadFiles?limit=200")
        matches = [row for row in rows if row["attributes"].get("assetType") == kind]
        require(len(matches) <= 1, "Ambiguous version upload file")
        saved = self.state.data["files"].get(kind)
        if not matches:
            require(not saved, "Saved upload file is absent from version")
            matches = [self.api.request("POST", "/v1/backgroundAssetUploadFiles", {"data": {
                "type": "backgroundAssetUploadFiles", "attributes": {
                    "assetType": kind, "fileName": artifact.file_name, "fileSize": artifact.size},
                "relationships": {"backgroundAssetVersion": {"data": {
                    "type": "backgroundAssetVersions", "id": self.state.data["version_id"]}}}}})["data"]]
        record = matches[0]
        self.verify_file_identity(record, kind)
        require(not saved or saved["id"] == record["id"], "Saved upload file ID changed")
        self.state.data["files"].setdefault(kind, {"id": record["id"], "completed_parts": [], "complete": False})
        self.state.save()

    def verify_file_identity(self, record, kind):
        expected = self.artifacts[kind]
        attrs = record["attributes"]
        require(attrs.get("assetType") == kind and attrs.get("fileSize") == expected.size
                and attrs.get("fileName") == expected.file_name, "Server file identity differs from approved artifact")

    def file(self, kind):
        record = self.api.request("GET", f"/v1/backgroundAssetUploadFiles/{self.state.data['files'][kind]['id']}")["data"]
        self.verify_file_identity(record, kind)
        return record

    def file_complete(self, record, kind):
        attrs = record["attributes"]
        delivery = attrs.get("assetDeliveryState", {})
        require(delivery.get("state") != "FAILED" and not delivery.get("errors"), "Apple rejected upload file")
        require(not delivery.get("warnings"), "Apple reported upload warnings; inspect ASC before continuing")
        if delivery.get("state") != "COMPLETE":
            return False
        checksums = (attrs.get("sourceFileChecksums") or {}).get("file") or {}
        expected = self.artifacts[kind]
        if checksums.get("hash"):
            algorithm = checksums.get("algorithm")
            digest = {"MD5": expected.md5, "SHA_256": expected.sha256}.get(algorithm)
            require(digest is not None and checksums["hash"].lower() == digest, "Server checksum differs from approved artifact")
            return True
        legacy = attrs.get("sourceFileChecksum")
        if legacy:
            require(legacy.lower() == expected.md5, "Server checksum differs from approved artifact")
            return True
        return False  # Apple can expose COMPLETE before its checksum becomes visible.

    def poll(self, check, label):
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            if check():
                return
            require(time.monotonic() < deadline, f"Timed out waiting for {label}; retain state and resume")
            self.sleep(self.poll_seconds)

    def upload_file(self, kind):
        self.ensure_file(kind)
        artifact, saved = self.artifacts[kind], self.state.data["files"][kind]
        record = self.file(kind)
        if self.file_complete(record, kind):
            saved["complete"] = True
            self.state.save()
            return
        if record["attributes"].get("assetDeliveryState", {}).get("state") == "AWAITING_UPLOAD":
            operations = record["attributes"].get("uploadOperations") or []
            part_ranges(operations, saved["completed_parts"], artifact.size)
            def send(operation):
                pair = [operation["offset"], operation["length"]]
                for attempt in range(4):
                    try:
                        if attempt:
                            self.sleep(min(2 ** attempt, 8))
                            fresh = self.file(kind)["attributes"].get("uploadOperations") or []
                            operation = next((o for o in fresh if [o["offset"], o["length"]] == pair), None)
                            require(operation is not None, "Apple upload range is unavailable; retain state and resume")
                        self.send_part(artifact, operation)
                        break
                    except UploadError as error:
                        status = getattr(error, "status", None)
                        self.reduce_part_limit(status)
                        emit("part_retry", kind=kind, offset=pair[0], length=pair[1],
                             attempt=attempt + 1, status=status)
                        if attempt == 3:
                            raise UploadError("Part upload failed after retries; retain state and resume") from None
                return pair
            pending = [op for op in operations if [op["offset"], op["length"]] not in saved["completed_parts"]]
            # The successful historical uploader used three parallel parts.
            # Streams stay bounded at 1 MiB each; state remains single-writer.
            with concurrent.futures.ThreadPoolExecutor(max_workers=8 if kind == "ASSET" else 1) as pool:
                futures = set()
                next_part = 0
                failure = None
                last_limit = None
                try:
                    while futures or (next_part < len(pending) and failure is None):
                        limit = self.part_limit() if kind == "ASSET" else 1
                        if last_limit != limit:
                            emit("parallel_limit", kind=kind, parallel_parts=limit)
                            last_limit = limit
                        while failure is None and len(futures) < limit and next_part < len(pending):
                            futures.add(pool.submit(send, pending[next_part]))
                            next_part += 1
                        done, _ = concurrent.futures.wait(futures, timeout=1,
                                                         return_when=concurrent.futures.FIRST_COMPLETED)
                        for future in done:
                            futures.remove(future)
                            try:
                                pair = future.result()
                            except Exception as error:
                                failure = failure or error
                                continue
                            saved["completed_parts"].append(pair)
                            self.state.save()
                            emit("part_uploaded", asset_pack_id=self.state.data["identity"]["asset_pack_id"],
                                 kind=kind, offset=pair[0], length=pair[1])
                finally:
                    # Cancellation must not drain all queued multi-GB parts.
                    for future in futures:
                        future.cancel()
                if failure:
                    raise failure
            part_ranges([], saved["completed_parts"], artifact.size)
            artifact.unchanged()
            self.api.request("PATCH", f"/v1/backgroundAssetUploadFiles/{saved['id']}", {"data": {
                "type": "backgroundAssetUploadFiles", "id": saved["id"], "attributes": {
                    "uploaded": True, "sourceFileChecksums": {"file": {"hash": artifact.md5, "algorithm": "MD5"}}}}})
        self.poll(lambda: self.file_complete(self.file(kind), kind), f"{kind} completion and checksum")
        saved["complete"] = True
        self.state.save()
        emit("file_verified", kind=kind, file_id=saved["id"])

    def run(self):
        require(self.api.allow_upload, "Explicit --upload is required")
        self.api.verify_target()
        self.ensure_version()
        self.upload_file("MANIFEST")
        # Manifest processing failure/warnings/checksum gaps cannot start the large upload.
        self.upload_file("ASSET")
        def complete():
            attrs = self.version()["attributes"]
            details = attrs.get("stateDetails") or {}
            require(attrs.get("state") != "FAILED" and not details.get("errors"), "Apple rejected asset version")
            require(not details.get("warnings"), "Apple reported version warnings; inspect ASC")
            if attrs.get("state") != "COMPLETE":
                return False
            require(attrs.get("platforms") == [PLATFORM], "Processed asset does not target iOS only")
            self.state.data.update(status="COMPLETE", version=attrs["version"])
            self.state.save()
            return True
        self.poll(complete, "asset version processing")
        files = []
        for kind in ("MANIFEST", "ASSET"):
            row = self.file(kind)
            require(self.file_complete(row, kind), "Completed file checksum is no longer available")
            attrs = row["attributes"]
            checksum = (attrs.get("sourceFileChecksums") or {}).get("file")
            files.append({"id": row["id"], "assetType": kind, "fileName": attrs["fileName"],
                          "fileSize": attrs["fileSize"], "state": "COMPLETE",
                          "serverFileChecksum": checksum or {"algorithm": "MD5", "hash": attrs["sourceFileChecksum"]},
                          "approvedSHA256": self.artifacts[kind].sha256})
        receipt = {"schemaVersion": 1, "appID": APP_ID, "bundleID": BUNDLE_ID, "platforms": [PLATFORM],
                   "assetPackID": self.state.data["identity"]["asset_pack_id"],
                   "assetRecordID": self.state.data["asset_id"], "versionID": self.state.data["version_id"],
                   "version": self.state.data["version"], "serverState": "COMPLETE", "files": files,
                   "errorCodes": [], "warningCodes": [], "verifiedAtUnixSeconds": int(time.time()),
                   "scope": "Upload and processing only; no beta/review/release activation"}
        receipt_path = self.state.path.with_suffix(".receipt.json")
        fd, temporary = tempfile.mkstemp(prefix=receipt_path.name + ".", dir=receipt_path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(receipt, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, receipt_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        emit("complete", asset_pack_id=self.state.data["identity"]["asset_pack_id"],
             asset_id=self.state.data["asset_id"], version_id=self.state.data["version_id"],
             version=self.state.data["version"], platform=PLATFORM, receipt=str(receipt_path))


@contextlib.contextmanager
def lock_state(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise UploadError("Another uploader owns this resume state") from None
        yield
    finally:
        os.close(fd)


def main():
    packs, catalog_hash = load_catalog()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-pack-id", required=True, choices=sorted(packs))
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--key-path", required=True, type=Path)
    parser.add_argument("--upload", action="store_true", help="Permit upload mutations after approved artifact verification")
    parser.add_argument("--poll-seconds", type=float, default=15)
    parser.add_argument("--timeout-seconds", type=float, default=3600)
    parser.add_argument("--parallel-parts", type=int, default=3)
    parser.add_argument("--parallel-control", type=Path,
                        help="Optional runtime JSON containing parallel_parts (1..8); apply with atomic replacement")
    args = parser.parse_args()
    require(0 < args.poll_seconds <= 60 and args.timeout_seconds > 0 and 1 <= args.parallel_parts <= 8,
            "Invalid polling or parallel-part limits")
    pack = packs[args.asset_pack_id]
    require(args.archive.name == pack["displayName"] + ".aar", "Archive filename differs from App display name")
    manifest = Artifact.inspect(args.manifest, args.manifest_sha256, "Manifest.json")
    require(manifest.size <= 4 * 1024 * 1024, "Manifest exceeds size limit")
    validate_manifest(json.loads(manifest.path.read_bytes()), pack)
    archive = reuse_verified_preflight(args.state, args.archive, args.archive_sha256, manifest,
                                       args.asset_pack_id, catalog_hash)
    if archive is None:
        archive = Artifact.inspect(args.archive, args.archive_sha256)
        verify_outer_manifest(archive, manifest)
    else:
        emit("verified_preflight_reused", asset_pack_id=args.asset_pack_id)
    identity = {"app_id": APP_ID, "bundle_id": BUNDLE_ID, "platform": PLATFORM,
                "asset_pack_id": args.asset_pack_id, "catalog_sha256": catalog_hash,
                "artifacts": {"MANIFEST": manifest.identity(), "ASSET": archive.identity()}}
    api = API(args.key_id, args.issuer, args.key_path, allow_upload=args.upload)
    api.verify_target()
    emit("preflight_passed", asset_pack_id=args.asset_pack_id, app_id=APP_ID, bundle_id=BUNDLE_ID,
         platform=PLATFORM, archive_sha256=archive.sha256, manifest_sha256=manifest.sha256,
         mutation_enabled=args.upload)
    if args.upload:
        with lock_state(args.state):
            state = ResumeState(args.state, identity)
            state.data["validated_preflight"] = {"archive_stat": list(archive.signature),
                "manifest_stat": list(manifest.signature), "outer_manifest_verified": True}
            state.save()
            Uploader(api, state, {"MANIFEST": manifest, "ASSET": archive}, poll_seconds=args.poll_seconds,
                     timeout_seconds=args.timeout_seconds, parallel_parts=args.parallel_parts,
                     parallel_control=args.parallel_control).run()


if __name__ == "__main__":
    try:
        main()
    except UploadError as error:
        emit("error", message=str(error))
        raise SystemExit(1)
    except KeyboardInterrupt:
        emit("interrupted", message="Retain the resume state and rerun the same approved artifacts")
        raise SystemExit(130)
    except Exception as error:
        emit("error", message="Unexpected " + type(error).__name__ + "; retain state and inspect locally")
        raise SystemExit(1)
