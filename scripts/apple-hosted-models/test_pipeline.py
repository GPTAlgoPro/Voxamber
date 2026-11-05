import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

import prepare_pack as builder
import upload_model as upload
import provision_hosting as provisioning


class PayloadGuards(unittest.TestCase):
    def test_catalog_and_platform_are_exact_target(self):
        packs, _ = upload.load_catalog()
        self.assertEqual(set(packs), {"Voxamber-Qwen35-4B-INT4"})
        manifest = json.loads((builder.SPEC_ROOT / "asset-manifest.json").read_text())
        upload.validate_manifest(manifest, next(iter(packs.values())))
        manifest["platforms"] = ["macOS"]
        with self.assertRaises(upload.UploadError):
            upload.validate_manifest(manifest, next(iter(packs.values())))

    def test_manifest_cannot_include_unlisted_payload_or_automatic_downloads(self):
        packs, _ = upload.load_catalog()
        pack = next(iter(packs.values()))
        manifest = json.loads((builder.SPEC_ROOT / "asset-manifest.json").read_text())
        manifest["fileSelectors"].append({"file": "unexpected.py"})
        with self.assertRaises(upload.UploadError):
            upload.validate_manifest(manifest, pack)
        manifest = json.loads((builder.SPEC_ROOT / "asset-manifest.json").read_text())
        manifest["downloadPolicy"] = {"essential": {"installationEventTypes": ["firstInstallation"]}}
        with self.assertRaises(upload.UploadError):
            upload.validate_manifest(manifest, pack)

    def test_wrong_app_identity_fails_before_any_mutation(self):
        api = object.__new__(upload.API)
        calls = []
        def request(method, path):
            calls.append(method)
            return {"data": {"id": "another-app", "attributes": {"bundleId": "com.snap3d.app"}}}
        api.request = request
        with self.assertRaises(upload.UploadError):
            api.verify_target()
        self.assertEqual(calls, ["GET"])

    def test_local_file_hash_and_nonexecutable_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "data.json"
            file.write_bytes(b"pinned")
            pin = {"relativePath": "data.json", "byteCount": 6, "sha256": hashlib.sha256(b"pinned").hexdigest()}
            builder.verify_file(file, pin)
            file.chmod(0o755)
            with self.assertRaises(ValueError):
                builder.verify_file(file, pin)
            file.chmod(0o644)
            file.write_bytes(b"edited")
            with self.assertRaises(ValueError):
                builder.verify_file(file, pin)

    def test_symlink_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.write_bytes(b"data")
            link = Path(directory) / "link"
            link.symlink_to(source)
            with self.assertRaises(ValueError):
                builder.verify_file(link, {"relativePath": "link", "byteCount": 4, "sha256": hashlib.sha256(b"data").hexdigest()})


class TransportGuards(unittest.TestCase):
    def test_range_coverage_cannot_have_gaps_or_overlaps(self):
        upload.part_ranges([{"offset": 0, "length": 5}], [[5, 5]], 10)
        for operations in ([{"offset": 1, "length": 9}], [{"offset": 0, "length": 7}, {"offset": 5, "length": 5}]):
            with self.assertRaises(upload.UploadError):
                upload.part_ranges(operations, [], 10)

    def test_only_apple_https_upload_destinations_are_allowed(self):
        artifact = SimpleNamespace(size=10)
        for url in ["http://upload.apple.com/a", "https://apple.com.evil.test/a", "https://evilapple.com/a", "https://user@upload.apple.com/a"]:
            with self.assertRaises(upload.UploadError):
                upload.put_part(artifact, {"url": url, "method": "PUT", "offset": 0, "length": 10})

    def test_transport_headers_cannot_leak_account_authorization(self):
        artifact = SimpleNamespace(size=10)
        for header in [{"name": "Authorization", "value": "not-permitted"}, {"name": "x-test", "value": "bad\r\nheader"}]:
            with self.assertRaises(upload.UploadError):
                upload.put_part(artifact, {"url": "https://upload.apple.com/a", "method": "PUT", "offset": 0, "length": 10, "requestHeaders": [header]})

    def test_resume_state_never_persists_signed_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            state = upload.ResumeState(Path(directory) / "state.json", {"app_id": upload.APP_ID})
            state.data["files"]["ASSET"] = {"id": "file", "completed_parts": [[0, 10]], "complete": False}
            state.save()
            self.assertNotIn("https://", state.path.read_text())
            state.data["files"]["ASSET"]["uploadOperations"] = []
            with self.assertRaises(upload.UploadError):
                state.save()

    def test_resume_state_cannot_be_reused_for_another_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            state = upload.ResumeState(path, {"app_id": upload.APP_ID, "sha256": "first"})
            state.save()
            with self.assertRaises(upload.UploadError):
                upload.ResumeState(path, {"app_id": upload.APP_ID, "sha256": "second"})

    def test_complete_requires_matching_server_checksum(self):
        artifact = SimpleNamespace(md5="a" * 32, sha256="b" * 64)
        uploader = upload.Uploader(None, None, {"ASSET": artifact})
        row = {"attributes": {"assetDeliveryState": {"state": "COMPLETE"}}}
        self.assertFalse(uploader.file_complete(row, "ASSET"))
        row["attributes"]["sourceFileChecksums"] = {"file": {"algorithm": "SHA_256", "hash": "b" * 64}}
        self.assertTrue(uploader.file_complete(row, "ASSET"))
        row["attributes"]["sourceFileChecksums"]["file"]["hash"] = "c" * 64
        with self.assertRaises(upload.UploadError):
            uploader.file_complete(row, "ASSET")

    def test_server_failure_or_warning_is_not_success(self):
        uploader = upload.Uploader(None, None, {})
        for state in [{"state": "FAILED"}, {"state": "COMPLETE", "warnings": [{"code": "warning"}]}]:
            with self.assertRaises(upload.UploadError):
                uploader.file_complete({"attributes": {"assetDeliveryState": state}}, "ASSET")

    def test_uncertain_version_creation_is_reconciled_without_another_post(self):
        state = SimpleNamespace(data={"identity": {"asset_pack_id": builder.ASSET_ID}, "asset_id": "asset",
            "version_creation_pending": True, "baseline_version_ids": ["old"], "files": {}}, save=lambda: None)
        class FakeAPI:
            def rows(self, path):
                if path.startswith("/v1/apps/"):
                    return [{"id": "asset", "attributes": {"assetPackIdentifier": builder.ASSET_ID}}]
                return [{"id": "old"}, {"id": "new"}]
            def request(self, *args):
                raise AssertionError("An interrupted version creation must not be repeated")
        upload.Uploader(FakeAPI(), state, {}).ensure_version()
        self.assertEqual(state.data["version_id"], "new")
        self.assertFalse(state.data["version_creation_pending"])


class ProvisioningGuards(unittest.TestCase):
    def test_child_identifier_cannot_replace_exact_main_bundle(self):
        class FakeAPI:
            def rows(self, path):
                return [
                    {"id": "child", "attributes": {"identifier": provisioning.EXTENSION_ID, "seedId": provisioning.TEAM}},
                    {"id": "main", "attributes": {"identifier": upload.BUNDLE_ID, "seedId": provisioning.TEAM}}
                ]
        self.assertEqual(provisioning.bundle(FakeAPI(), upload.BUNDLE_ID, "Voxamber", False)["id"], "main")

    def test_capability_change_is_bound_to_exact_bundle_record(self):
        calls = []
        class FakeAPI:
            def rows(self, path):
                self_path = "/v1/bundleIds/main/bundleIdCapabilities"
                if path != self_path:
                    raise AssertionError("Unexpected provisioning resource")
                return [] if not calls else [{"id": "capability", "attributes": {"capabilityType": "APP_GROUPS"}}]
            def request(self, method, path, payload):
                calls.append((method, path, payload))
        result = provisioning.capability(FakeAPI(), {"id": "main", "attributes": {"identifier": upload.BUNDLE_ID}}, True)
        self.assertTrue(result["appGroupsCapabilityPresent"])
        self.assertEqual(calls[0][0:2], ("POST", "/v1/bundleIdCapabilities"))
        self.assertEqual(calls[0][2]["data"]["relationships"]["bundleId"]["data"]["id"], "main")

    def test_other_team_bundle_is_rejected(self):
        class FakeAPI:
            def rows(self, path):
                return [{"id": "main", "attributes": {"identifier": upload.BUNDLE_ID, "seedId": "OTHERTEAM"}}]
        with self.assertRaises(upload.UploadError):
            provisioning.bundle(FakeAPI(), upload.BUNDLE_ID, "Voxamber", False)


if __name__ == "__main__":
    unittest.main()
