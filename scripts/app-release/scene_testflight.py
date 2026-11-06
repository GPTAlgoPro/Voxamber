#!/usr/bin/env python3
"""Scoped TestFlight 0.2.0 (10) preflight; remote mutations are opt-in and journaled.

No upload, invitation, beta review, App Store submission, or public release API exists
in this helper. The JWT implementation is imported only after its source hash matches.
"""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parents[2]
APP_ID = "6831042755"
BUNDLE_ID = "com.kaisun.voxamber"
VERSION = "0.2.0"
BUILD = "10"
GROUP_ID = "7d4c4aba-14b9-423e-b1ae-d50ce983d527"
TRUSTED_BASE_SHA = "f04e87d475c043551a6b395dda1001ce3716852c7ec2e7ebc8067a1d1f4f8089"
AUTH = ROOT / "Apple/.build/scene-testflight7/auth-config.private.json"
STATE = ROOT / "Apple/.build/scene-testflight10/distribution-journal.private.json"
NOTES = {
    "zh-Hans": "本版改为场景源码导入优先：从你自己的 AI 应用复制源码，或导入 .js、.txt、.html 文件，在 iPhone 本机生成、预览、保存和导出三维模型；无需下载本地 AI 模型。保留历史作品的只读预览和导出入口。不远程读取聊天会话链接。复杂场景的 SDK 覆盖范围仍需实测，请反馈生成失败或显示异常的源码。",
    "en-US": "Import scene source from your own AI app by pasting code or opening .js, .txt, or .html files. Generate, preview, save, and export 3D models locally on iPhone, without downloading an AI model. Existing works remain available for read-only preview and export. Conversation URLs are not fetched remotely. SDK coverage for complex scenes still needs testing; please report source that fails to generate or display correctly.",
}


class GuardError(Exception):
    """Only sanitized, locally authored messages may cross this boundary."""


def require(condition, message):
    if not condition:
        raise GuardError(message)


def safe_id(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9-]{1,80}", value), "Invalid resource ID")
    return value


def read_json(path):
    path = Path(path)
    require(not path.is_symlink() and path.is_file() and path.stat().st_size <= 1024 * 1024,
            "Local JSON is unavailable, oversized, or a symlink")
    return json.loads(path.read_text(encoding="utf-8"))


def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scope(build_id):
    return dict(appID=APP_ID, bundleID=BUNDLE_ID, marketingVersion=VERSION,
                buildNumber=BUILD, buildID=safe_id(build_id), groupID=GROUP_ID)


def validate_distribution_evidence(audit_path, approval_path, build_id):
    audit = read_json(audit_path)
    expected = scope(build_id)
    require(audit.get("status") == "PASS", "IPA audit did not pass")
    for key in ("appID", "bundleID", "marketingVersion", "buildNumber"):
        require(audit.get(key) == expected[key], "IPA audit scope differs")
    raw_path = audit.get("ipaPath")
    require(isinstance(raw_path, str) and Path(raw_path).is_absolute(), "IPA path must be absolute")
    ipa = Path(raw_path)
    require(not ipa.is_symlink() and ipa.is_file(), "Audited IPA is unavailable or a symlink")
    before = ipa.stat()
    require(type(audit.get("ipaByteCount")) is int and before.st_size == audit["ipaByteCount"] > 0,
            "IPA byte count differs")
    sha = audit.get("ipaSHA256")
    require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha), "Invalid IPA SHA256")
    require(file_sha(ipa) == sha, "IPA SHA256 differs")
    with zipfile.ZipFile(ipa) as archive:
        infos = [item for item in archive.infolist()
                 if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", item.filename)]
        require(len(infos) == 1 and infos[0].file_size <= 1024 * 1024, "IPA main bundle is ambiguous")
        info = plistlib.loads(archive.read(infos[0]))
    require((info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"),
             info.get("CFBundleVersion")) == (BUNDLE_ID, VERSION, BUILD), "IPA bundle identity differs")
    after = ipa.stat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            "IPA changed during evidence verification")
    approval = read_json(approval_path)
    require(approval.get("approved") is True and approval.get("action") == "distribute-internal-build",
            "Explicit scoped distribution approval is required")
    for key, value in {**expected, "ipaSHA256": sha}.items():
        require(approval.get(key) == value, "Distribution approval scope differs")
    return {**expected, "ipaSHA256": sha, "ipaByteCount": before.st_size}


def trusted_transport(distribute):
    base_path = ROOT / "scripts/apple-hosted-models/upload_model.py"
    require(file_sha(base_path) == TRUSTED_BASE_SHA, "JWT base source differs from the reviewed pin")
    config = read_json(AUTH)
    require(all(isinstance(config.get(key), str) and config[key] for key in ("key_id", "issuer", "key_path")),
            "Private authentication configuration is incomplete")
    spec = importlib.util.spec_from_file_location("scene_testflight_trusted_base", base_path)
    module = importlib.util.module_from_spec(spec)
    # dataclass resolves the owning module during import.
    import sys
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.API(config["key_id"], config["issuer"], config["key_path"], allow_upload=distribute)


class ScopedAPI:
    """Deny arbitrary ASC paths and mutation payloads even with a write-capable JWT base."""
    def __init__(self, transport, distribute=False):
        self.transport, self.distribute = transport, distribute
        self.build_id = None
        self.localization_ids = {}

    def request(self, method, path, payload=None):
        parsed = urllib.parse.urlsplit(path)
        require(not parsed.scheme and not parsed.netloc and not parsed.fragment and "%" not in parsed.path,
                "Only scoped relative ASC paths are permitted")
        query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
        require(all(len(values) == 1 for values in query.values()), "Duplicate ASC query key")
        route = parsed.path
        fixed = {
            f"/v1/apps/{APP_ID}": {"fields[apps]": "bundleId"},
            f"/v1/betaGroups/{GROUP_ID}": {"fields[betaGroups]": "isInternalGroup,publicLinkEnabled"},
            f"/v1/betaGroups/{GROUP_ID}/app": {"fields[apps]": "bundleId"},
            f"/v1/betaGroups/{GROUP_ID}/relationships/betaTesters": {"limit": "200"},
            f"/v1/betaGroups/{GROUP_ID}/relationships/builds": {"limit": "200"},
            "/v1/builds": {"filter[app]": APP_ID, "filter[version]": BUILD,
                           "include": "app,preReleaseVersion", "limit": "200"},
        }
        if self.build_id:
            fixed.update({
                f"/v1/builds/{self.build_id}/buildBetaDetail": {},
                f"/v1/builds/{self.build_id}/betaBuildLocalizations": {"limit": "200"},
            })
        if method == "GET":
            require(payload is None and route in fixed, "GET is outside the TestFlight scope")
            expected = fixed[route]
            values = {key: value[0] for key, value in query.items()}
            cursor = values.pop("page[cursor]", None)
            require(values == expected and (cursor is None or 0 < len(cursor) <= 2048),
                    "GET query differs from the pinned scope")
        else:
            require(self.distribute and self.build_id and not parsed.query, "Remote mutation is disabled")
            valid = False
            if method == "POST" and route == "/v1/betaBuildLocalizations":
                data = payload.get("data", {}) if isinstance(payload, dict) else {}
                locale = data.get("attributes", {}).get("locale")
                valid = locale in NOTES and payload == localization_payload(self.build_id, locale)
            elif method == "PATCH" and route.startswith("/v1/betaBuildLocalizations/"):
                item_id = route.rsplit("/", 1)[1]
                data = payload.get("data", {}) if isinstance(payload, dict) else {}
                locale = self.localization_ids.get(item_id)
                valid = locale in NOTES and payload == update_payload(item_id, locale)
            elif method == "POST" and route == f"/v1/betaGroups/{GROUP_ID}/relationships/builds":
                valid = payload == {"data": [{"type": "builds", "id": self.build_id}]}
            require(valid, "Mutation path or payload is outside the TestFlight scope")
        return self.transport.request(method, path, payload)

    def get(self, route, **query):
        return self.request("GET", route + ("?" + urllib.parse.urlencode(query) if query else ""))

    def rows(self, route, **query):
        result = self.get(route, **query)
        rows = list(result["data"])
        visited = set()
        while result.get("links", {}).get("next"):
            next_url = result["links"]["next"]
            require(next_url not in visited and len(visited) < 100, "ASC pagination did not terminate")
            visited.add(next_url)
            parsed = urllib.parse.urlsplit(next_url)
            require(parsed.scheme == "https" and parsed.netloc == "api.appstoreconnect.apple.com"
                    and parsed.path == route and not parsed.fragment, "Unexpected pagination target")
            result = self.request("GET", parsed.path + "?" + parsed.query)
            rows.extend(result["data"])
        return rows


def localization_payload(build_id, locale):
    return {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": NOTES[locale]},
                     "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}


def update_payload(item_id, locale):
    return {"data": {"type": "betaBuildLocalizations", "id": item_id, "attributes": {"whatsNew": NOTES[locale]}}}


def preflight(api, requested_build_id=None):
    app = api.get(f"/v1/apps/{APP_ID}", **{"fields[apps]": "bundleId"})["data"]
    require(app["id"] == APP_ID and app["attributes"]["bundleId"] == BUNDLE_ID, "App identity differs")
    group = api.get(f"/v1/betaGroups/{GROUP_ID}", **{"fields[betaGroups]": "isInternalGroup,publicLinkEnabled"})["data"]
    require(group["id"] == GROUP_ID and group["attributes"].get("isInternalGroup") is True
            and group["attributes"].get("publicLinkEnabled") is not True, "Group must remain internal and private")
    owner = api.get(f"/v1/betaGroups/{GROUP_ID}/app", **{"fields[apps]": "bundleId"})["data"]
    require(owner["id"] == APP_ID and owner["attributes"]["bundleId"] == BUNDLE_ID, "Group belongs to another app")
    testers = api.rows(f"/v1/betaGroups/{GROUP_ID}/relationships/betaTesters", limit="200")
    require(all(set(row) <= {"id", "type"} and row.get("type") == "betaTesters" for row in testers),
            "Tester endpoint returned unexpected personal attributes")
    require(len(testers) == 1, "Existing self-only group membership changed; distribution is prohibited")
    response = api.get("/v1/builds", **{"filter[app]": APP_ID, "filter[version]": BUILD,
                                      "include": "app,preReleaseVersion", "limit": "200"})
    require(not response.get("links", {}).get("next"), "Build lookup is incomplete")
    candidates = response["data"]
    if requested_build_id:
        candidates = [row for row in candidates if row["id"] == requested_build_id]
    require(len(candidates) <= 1, "Matching build is ambiguous; supply the actual build ID")
    summary = {"appID": APP_ID, "marketingVersion": VERSION, "buildNumber": BUILD,
               "groupID": GROUP_ID, "internalTesterCount": len(testers), "mutationCount": 0}
    if not candidates:
        require(not requested_build_id, "Requested build is absent from the exact app/build lookup")
        return {**summary, "status": "BUILD_NOT_FOUND"}, None
    build = candidates[0]
    attrs, relationships = build["attributes"], build["relationships"]
    require(attrs.get("version") == BUILD and relationships["app"]["data"]["id"] == APP_ID,
            "Build app or number differs")
    pre_id = relationships["preReleaseVersion"]["data"]["id"]
    prereleases = [row for row in response.get("included", [])
                   if row.get("type") == "preReleaseVersions" and row["id"] == pre_id]
    require(len(prereleases) == 1 and prereleases[0]["attributes"].get("version") == VERSION
            and prereleases[0]["attributes"].get("platform") == "IOS", "Build prerelease version/platform differs")
    api.build_id = safe_id(build["id"])
    detail = api.get(f"/v1/builds/{api.build_id}/buildBetaDetail")["data"]
    internal = detail["attributes"].get("internalBuildState")
    members = api.rows(f"/v1/betaGroups/{GROUP_ID}/relationships/builds", limit="200")
    require(all(set(row) <= {"id", "type"} and row.get("type") == "builds" for row in members),
            "Unexpected group build relationship")
    ready = attrs.get("processingState") == "VALID" and attrs.get("expired") is False and internal in {
        "READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}
    return {**summary, "status": "READY" if ready else "NOT_READY", "buildID": api.build_id,
            "processingState": attrs.get("processingState"), "internalBuildState": internal,
            "alreadyInGroup": any(row["id"] == api.build_id for row in members)}, build


class Journal:
    def __init__(self, path, identity):
        self.path = Path(path)
        self.identity = identity
        self.data = {"identity": identity, "operations": {}}
        if self.path.exists():
            self.data = read_json(self.path)
            require(self.data.get("identity") == identity, "Journal belongs to different distribution evidence")

    @contextlib.contextmanager
    def lock(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = self.path.with_suffix(".lock")
        require(not lock_path.is_symlink(), "Journal lock must not be a symlink")
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Refresh under lock; another process may have finished before this lock.
            if self.path.exists():
                self.data = read_json(self.path)
                require(self.data.get("identity") == self.identity, "Journal identity changed")
            yield

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        require(not self.path.is_symlink(), "Journal must not be a symlink")
        fd, temporary = tempfile.mkstemp(prefix=".testflight-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(self.data, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def reconcile_or_issue(self, key, confirmed, action):
        operations = self.data["operations"]
        if confirmed():
            operations[key] = "verified"
            self.save()
            return False
        require(key not in operations, "Prior mutation outcome is unresolved; GET did not confirm it; no retry issued")
        operations[key] = "pending"  # Durable BEFORE the only POST/PATCH attempt.
        self.save()
        try:
            action()
        except Exception:
            # A lost response, including a successful empty 204 parsed by the base,
            # is reconciled by GET, never by repeating the mutation.
            require(confirmed(), "Mutation outcome is unknown; GET did not confirm it; journal retained; no retry issued")
            operations[key] = "verified"
            self.save()
            return True
        require(confirmed(), "Mutation was not confirmed by GET; journal retained; no retry issued")
        operations[key] = "verified"
        self.save()
        return True


def distribute(api, summary, evidence, journal):
    require(api.distribute and summary["status"] == "READY" and summary.get("buildID") == evidence["buildID"],
            "Only a ready, audited, explicitly approved build can be distributed")
    mutations = 0
    with journal.lock():
        for locale in NOTES:
            def localization(locale=locale):
                rows = api.rows(f"/v1/builds/{api.build_id}/betaBuildLocalizations", limit="200")
                matches = [row for row in rows if row["attributes"].get("locale") == locale]
                require(len(matches) <= 1, "Duplicate beta localization requires manual review")
                if matches:
                    item_id = safe_id(matches[0]["id"])
                    api.localization_ids[item_id] = locale
                    return matches[0]
                return None

            existing = localization()

            def confirmed():
                current = localization()
                return current is not None and current["attributes"].get("whatsNew") == NOTES[locale]

            def action():
                if existing:
                    api.request("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}", update_payload(existing["id"], locale))
                else:
                    api.request("POST", "/v1/betaBuildLocalizations", localization_payload(api.build_id, locale))

            key = "notes:" + locale + ":" + hashlib.sha256(NOTES[locale].encode()).hexdigest()
            mutations += journal.reconcile_or_issue(key, confirmed, action)

        def member():
            rows = api.rows(f"/v1/betaGroups/{GROUP_ID}/relationships/builds", limit="200")
            return any(row.get("type") == "builds" and row.get("id") == api.build_id for row in rows)

        mutations += journal.reconcile_or_issue("group-build", member, lambda: api.request(
            "POST", f"/v1/betaGroups/{GROUP_ID}/relationships/builds",
            {"data": [{"type": "builds", "id": api.build_id}]}))
    return {**summary, "status": "DISTRIBUTED_INTERNAL", "mutationCount": mutations,
            "localesVerified": list(NOTES), "alreadyInGroup": True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-id")
    parser.add_argument("--distribute", action="store_true")
    parser.add_argument("--audit", type=Path)
    parser.add_argument("--approval", type=Path)
    parser.add_argument("--journal", type=Path, default=STATE)
    args = parser.parse_args(argv)
    try:
        evidence = None
        if args.build_id:
            safe_id(args.build_id)
        if args.distribute:
            require(args.build_id and args.audit and args.approval, "Distribution requires actual build ID, IPA audit, and approval")
            evidence = validate_distribution_evidence(args.audit, args.approval, args.build_id)
        api = ScopedAPI(trusted_transport(args.distribute), args.distribute)
        summary, _ = preflight(api, args.build_id)
        if args.distribute:
            identity = {**evidence, "notesSHA256": hashlib.sha256(
                json.dumps(NOTES, sort_keys=True, ensure_ascii=False).encode()).hexdigest()}
            summary = distribute(api, summary, evidence, Journal(args.journal, identity))
        print(json.dumps(summary, sort_keys=True))
        return 0
    except GuardError as error:
        print(json.dumps({"status": "STOPPED", "reason": str(error)}))
        return 1
    except Exception:
        # Do not stringify transport/config exceptions: their raw values can contain secrets.
        print(json.dumps({"status": "STOPPED", "reason": "Scoped preflight, evidence, or reconciliation failed; no automatic retry"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
