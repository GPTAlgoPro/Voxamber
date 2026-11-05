from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import upload_model as transport
import upload_neural_packs as adapter


class NeuralUploadGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.identity = {"app_id": adapter.APP_ID, "asset_pack_id": adapter.ALLOWLIST["intent"][1],
                         "approval_sha256": "a" * 64}
        self.artifacts = {
            "MANIFEST": SimpleNamespace(file_name="Manifest.json", size=10, md5="a" * 32, sha256="b" * 64),
            "ASSET": SimpleNamespace(file_name=adapter.ALLOWLIST["intent"][1] + ".aar", size=100, md5="c" * 32, sha256="d" * 64),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def api(self, allow_upload=True):
        api = object.__new__(adapter.ScopedAPI)  # No credentials/network initialized by fixture tests.
        api.pack_id = self.identity["asset_pack_id"]; api.artifacts = self.artifacts
        api.asset_ids, api.version_ids, api.file_ids = set(), set(), {}
        api.allow_upload = allow_upload
        api.journal = adapter.CreationJournal(self.root / "creation.json", self.identity)
        return api

    def asset(self):
        return {"id": "new-asset", "attributes": {"assetPackIdentifier": self.identity["asset_pack_id"]}}

    def file(self, kind="MANIFEST"):
        a = self.artifacts[kind]
        return {"id": kind.lower() + "-file", "attributes": {"assetType": kind, "fileName": a.file_name, "fileSize": a.size}}

    def asset_payload(self, app=None, pack=None):
        return {"data": {"type": "backgroundAssets", "attributes": {"assetPackIdentifier": pack or self.identity["asset_pack_id"]},
            "relationships": {"app": {"data": {"type": "apps", "id": app or adapter.APP_ID}}}}}

    def file_payload(self, version="new-version"):
        a = self.artifacts["MANIFEST"]
        return {"data": {"type": "backgroundAssetUploadFiles", "attributes": {"assetType": "MANIFEST", "fileName": a.file_name, "fileSize": a.size},
            "relationships": {"backgroundAssetVersion": {"data": {"type": "backgroundAssetVersions", "id": version}}}}}

    def test_approval_is_exact_three_new_archives_and_unchanged_legacy_transport(self):
        rows, _, _ = adapter.load_approved()
        self.assertEqual(set(rows), {"intent", "image", "shape"})
        self.assertEqual({r["approval"]["assetPackID"] for r in rows.values()}, {v[1] for v in adapter.ALLOWLIST.values()})
        self.assertNotIn("Voxamber-Qwen35-4B-INT4", {r["approval"]["assetPackID"] for r in rows.values()})

    def test_manifest_extra_legal_script_missing_file_platform_and_download_policy_fail(self):
        rows, _, _ = adapter.load_approved(); approved = rows["intent"]
        source = adapter.builder.strict_json((adapter.ROOT / approved["approval"]["manifestPath"]).read_bytes())
        adapter.validate_manifest(source, approved)
        import copy
        for mutate in [lambda m: m["fileSelectors"].append({"file": "unexpected.py"}),
                       lambda m: m["fileSelectors"].pop(),
                       lambda m: m.update(platforms=["macOS"]),
                       lambda m: m.update(downloadPolicy={"essential": {}})]:
            changed = copy.deepcopy(source); mutate(changed)
            with self.assertRaises((transport.UploadError, ValueError)):
                adapter.validate_manifest(changed, approved)

    def test_dry_run_rejects_post_before_wire_or_journal_write(self):
        api = self.api(allow_upload=False)
        with patch.object(transport.API, "request") as wire:
            with self.assertRaises(transport.UploadError):
                api.request("POST", "/v1/backgroundAssets", self.asset_payload())
            wire.assert_not_called()
        self.assertFalse((self.root / "creation.json").exists())

    def test_other_app_legacy_pack_and_review_operations_cannot_reach_wire(self):
        api = self.api()
        operations = [
            ("POST", "/v1/backgroundAssets", self.asset_payload(app="another-app")),
            ("POST", "/v1/backgroundAssets", self.asset_payload(pack="Voxamber-Qwen35-4B-INT4")),
            ("GET", "/v1/apps/another-app", None),
            ("POST", "/v1/betaAppReviewSubmissions", {"data": {}}),
            ("PATCH", "/v1/appStoreVersions/some-version", {"data": {}}),
        ]
        with patch.object(transport.API, "request") as wire:
            for method, path, payload in operations:
                with self.assertRaises(transport.UploadError):
                    api.request(method, path, payload)
            wire.assert_not_called()

    def test_get_binding_excludes_legacy_and_unrelated_asset_children(self):
        api = self.api()
        def wire(_, method, path, payload=None):
            return {"data": [{"id": "legacy-asset", "attributes": {"assetPackIdentifier": "Voxamber-Qwen35-4B-INT4"}}, self.asset()]}
        with patch.object(transport.API, "request", wire):
            api.request("GET", f"/v1/apps/{adapter.APP_ID}/backgroundAssets?limit=200")
        self.assertEqual(api.asset_ids, {"new-asset"})
        with patch.object(transport.API, "request") as wire:
            with self.assertRaises(transport.UploadError):
                api.request("GET", "/v1/backgroundAssets/legacy-asset/versions")
            with self.assertRaises(transport.UploadError):
                api.request("POST", "/v1/backgroundAssetUploadFiles", self.file_payload(version="foreign-version"))
            wire.assert_not_called()

    def test_wrong_upload_name_size_or_completion_checksum_rejected(self):
        api = self.api(); api.version_ids.add("new-version"); api.file_ids["manifest-file"] = "MANIFEST"
        wrong = self.file_payload(); wrong["data"]["attributes"]["fileSize"] += 1
        with patch.object(transport.API, "request") as wire:
            with self.assertRaises(transport.UploadError):
                api.request("POST", "/v1/backgroundAssetUploadFiles", wrong)
            with self.assertRaises(transport.UploadError):
                api.request("PATCH", "/v1/backgroundAssetUploadFiles/manifest-file", {"data": {
                    "type": "backgroundAssetUploadFiles", "id": "manifest-file", "attributes": {
                        "uploaded": True, "sourceFileChecksums": {"file": {"hash": "0" * 32, "algorithm": "MD5"}}}}})
            wire.assert_not_called()

    def test_uncertain_asset_post_cannot_repeat_until_get_reconciles(self):
        api = self.api(); calls = []
        def wire(_, method, path, payload=None):
            calls.append(method)
            if method == "POST": raise transport.UploadError("Uncertain fixture outcome")
            return {"data": [self.asset()]}
        with patch.object(transport.API, "request", wire):
            for _ in range(2):
                with self.assertRaises(transport.UploadError):
                    api.request("POST", "/v1/backgroundAssets", self.asset_payload())
            self.assertEqual(calls.count("POST"), 1)
            self.assertTrue(api.journal.pending("asset"))
            api.request("GET", f"/v1/apps/{adapter.APP_ID}/backgroundAssets?limit=200")
        self.assertFalse(api.journal.pending("asset"))
        self.assertEqual(api.asset_ids, {"new-asset"})

    def test_uncertain_file_post_cannot_repeat_until_owned_list_reconciles(self):
        api = self.api(); api.version_ids.add("new-version"); calls = []
        def wire(_, method, path, payload=None):
            calls.append(method)
            if method == "POST": raise transport.UploadError("Uncertain fixture outcome")
            return {"data": [self.file()]}
        with patch.object(transport.API, "request", wire):
            for _ in range(2):
                with self.assertRaises(transport.UploadError):
                    api.request("POST", "/v1/backgroundAssetUploadFiles", self.file_payload())
            self.assertEqual(calls.count("POST"), 1)
            api.request("GET", "/v1/backgroundAssetVersions/new-version/backgroundAssetUploadFiles")
        self.assertFalse(api.journal.pending("file_MANIFEST"))

    def test_uncertain_version_is_reconciled_without_a_second_version_post(self):
        state_path = self.root / "upload.json"
        state = transport.ResumeState(state_path, self.identity); state.save()
        api = self.api(); versions = [{"id": "old-version", "attributes": {}}]; posts = []
        def wire(_, method, path, payload=None):
            if method == "POST":
                posts.append(path); versions.append({"id": "new-version", "attributes": {}})
                raise transport.UploadError("Uncertain fixture outcome")
            return {"data": [self.asset()] if "/apps/" in path else list(versions)}
        with patch.object(transport.API, "request", wire):
            with self.assertRaises(transport.UploadError):
                transport.Uploader(api, state, self.artifacts).ensure_version()
            self.assertTrue(state.data["version_creation_pending"])
            resumed = transport.ResumeState(state_path, self.identity)
            transport.Uploader(self.api(), resumed, self.artifacts).ensure_version()
        self.assertEqual(posts, ["/v1/backgroundAssetVersions"])
        self.assertEqual(resumed.data["version_id"], "new-version")
        self.assertFalse(resumed.data["version_creation_pending"])

    def test_journal_and_resume_reject_changed_approval_and_never_save_access_urls(self):
        api = self.api(); api.journal.begin("asset")
        text = (self.root / "creation.json").read_text()
        self.assertNotIn("https://", text); self.assertNotIn("Bearer", text)
        with self.assertRaises(transport.UploadError):
            adapter.CreationJournal(self.root / "creation.json", {**self.identity, "approval_sha256": "b" * 64})

    def test_legacy_delivery_checker_requires_actual_complete_and_matching_digest(self):
        checker = transport.Uploader(None, None, self.artifacts)
        row = self.file(); row["attributes"]["assetDeliveryState"] = {"state": "COMPLETE"}
        self.assertFalse(checker.file_complete(row, "MANIFEST"))
        row["attributes"]["sourceFileChecksums"] = {"file": {"algorithm": "SHA_256", "hash": "b" * 64}}
        self.assertTrue(checker.file_complete(row, "MANIFEST"))
        row["attributes"]["sourceFileChecksums"]["file"]["hash"] = "0" * 64
        with self.assertRaises(transport.UploadError):
            checker.file_complete(row, "MANIFEST")


if __name__ == "__main__":
    unittest.main()
