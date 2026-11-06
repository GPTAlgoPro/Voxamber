"""Offline guard tests only: fake ASC responses and synthetic IPA identity fixtures."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse
import zipfile

SPEC = importlib.util.spec_from_file_location("scene_testflight", Path(__file__).with_name("scene_testflight.py"))
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
BUILD_ID = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"


class FakeASC:
    def __init__(self):
        self.calls = []
        self.present = True
        self.bundle = helper.BUNDLE_ID
        self.owner = helper.APP_ID
        self.internal = True
        self.public = False
        self.version = helper.VERSION
        self.platform = "IOS"
        self.processing = "VALID"
        self.beta_state = "READY_FOR_BETA_TESTING"
        self.expired = False
        self.locales = {}
        self.members = []
        self.post_unknown = False
        self.post_accepted = True
        self.tester_count = 1
        self.empty_group_response = False

    def request(self, method, path, payload=None):
        self.calls.append((method, path, copy.deepcopy(payload)))
        route = urllib.parse.urlsplit(path).path
        if method == "GET":
            if route == f"/v1/apps/{helper.APP_ID}":
                return {"data": {"id": helper.APP_ID, "attributes": {"bundleId": self.bundle}}}
            if route == f"/v1/betaGroups/{helper.GROUP_ID}":
                return {"data": {"id": helper.GROUP_ID, "attributes": {
                    "isInternalGroup": self.internal, "publicLinkEnabled": self.public}}}
            if route.endswith("/app"):
                return {"data": {"id": self.owner, "attributes": {"bundleId": self.bundle}}}
            if route.endswith("/relationships/betaTesters"):
                return {"data": [{"type": "betaTesters", "id": "private-linkage-only-" + str(index)}
                                 for index in range(self.tester_count)]}
            if route == "/v1/builds":
                return {"data": [{"id": BUILD_ID, "type": "builds", "attributes": {
                    "version": helper.BUILD, "processingState": self.processing, "expired": self.expired},
                    "relationships": {"app": {"data": {"id": helper.APP_ID}},
                                      "preReleaseVersion": {"data": {"id": "prv"}}}}] if self.present else [],
                    "included": [{"id": "prv", "type": "preReleaseVersions", "attributes": {
                        "version": self.version, "platform": self.platform}}]}
            if route.endswith("/buildBetaDetail"):
                return {"data": {"attributes": {"internalBuildState": self.beta_state}}}
            if route.endswith("/betaBuildLocalizations"):
                return {"data": list(copy.deepcopy(self.locales).values())}
            if route.endswith("/relationships/builds"):
                return {"data": [{"type": "builds", "id": item} for item in self.members]}
        if method == "POST" and route == "/v1/betaBuildLocalizations":
            locale = payload["data"]["attributes"]["locale"]
            if not self.post_unknown or self.post_accepted:
                self.locales[locale] = {"id": "locale-" + locale, "type": "betaBuildLocalizations",
                                       "attributes": copy.deepcopy(payload["data"]["attributes"])}
            if self.post_unknown:
                self.post_unknown = False
                raise OSError("synthetic lost response; must not be retried")
            return {"data": self.locales[locale]}
        if method == "PATCH" and route.startswith("/v1/betaBuildLocalizations/"):
            item_id = route.rsplit("/", 1)[-1]
            for item in self.locales.values():
                if item["id"] == item_id:
                    item["attributes"].update(payload["data"]["attributes"])
                    return {"data": item}
        if method == "POST" and route.endswith("/relationships/builds"):
            self.members.append(payload["data"][0]["id"])
            if self.empty_group_response:
                raise ValueError("synthetic empty 204 body cannot be JSON decoded")
            return {}
        raise AssertionError("Fake ASC received an unexpected route")


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        # An accidental real request is a test failure, even if network is available.
        self.network = patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("Network forbidden"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def prepared(self, transport=None):
        transport = transport or FakeASC()
        api = helper.ScopedAPI(transport, distribute=True)
        summary, _ = helper.preflight(api, BUILD_ID)
        evidence = {**helper.scope(BUILD_ID), "ipaSHA256": "a" * 64, "ipaByteCount": 100}
        journal = helper.Journal(self.directory / "journal.json", evidence)
        return transport, api, summary, evidence, journal

    def test_default_is_get_only_and_summary_contains_no_tester_identifiers(self):
        self.assertEqual(helper.BUILD, "10")
        self.assertIn("scene-testflight10", str(helper.STATE))
        self.assertIn("scene-testflight7/auth-config.private.json", str(helper.AUTH))
        fake = FakeASC()
        summary, _ = helper.preflight(helper.ScopedAPI(fake))
        self.assertEqual(summary["status"], "READY")
        self.assertEqual(summary["internalTesterCount"], 1)
        self.assertNotIn("private-linkage-only", json.dumps(summary))
        self.assertTrue(all(call[0] == "GET" for call in fake.calls))
        self.assertTrue(any("/relationships/betaTesters" in call[1] for call in fake.calls))
        self.assertFalse(any("/v1/betaTesters" in call[1] for call in fake.calls))

    def test_build_absence_is_readonly_and_explicit_missing_id_fails(self):
        fake = FakeASC()
        fake.present = False
        summary, build = helper.preflight(helper.ScopedAPI(fake))
        self.assertEqual(summary["status"], "BUILD_NOT_FOUND")
        self.assertIsNone(build)
        with self.assertRaises(helper.GuardError):
            helper.preflight(helper.ScopedAPI(fake), BUILD_ID)

    def test_self_only_membership_drift_fails_closed_without_contact_lookup(self):
        for count in (0, 2):
            fake = FakeASC()
            fake.tester_count = count
            with self.assertRaises(helper.GuardError):
                helper.preflight(helper.ScopedAPI(fake))
            self.assertTrue(all(row[0] == "GET" for row in fake.calls))

    def test_wrong_app_group_version_and_platform_are_rejected(self):
        for field, value in [("bundle", "other.app"), ("owner", "another-app"), ("internal", False),
                             ("public", True), ("version", "0.1.0"), ("platform", "MAC_OS")]:
            with self.subTest(field=field):
                fake = FakeASC()
                setattr(fake, field, value)
                with self.assertRaises(helper.GuardError):
                    helper.preflight(helper.ScopedAPI(fake), BUILD_ID)
                self.assertTrue(all(row[0] == "GET" for row in fake.calls))

    def test_processing_export_compliance_and_expired_builds_cannot_distribute(self):
        for field, value in [("processing", "PROCESSING"), ("beta_state", "MISSING_EXPORT_COMPLIANCE"),
                             ("beta_state", "UNKNOWN_NEW_STATE"), ("expired", True)]:
            with self.subTest(field=field):
                fake = FakeASC()
                setattr(fake, field, value)
                fake, api, summary, evidence, journal = self.prepared(fake)
                self.assertEqual(summary["status"], "NOT_READY")
                with self.assertRaises(helper.GuardError):
                    helper.distribute(api, summary, evidence, journal)
                self.assertTrue(all(row[0] == "GET" for row in fake.calls))

    def test_request_guard_denies_other_actions_urls_scopes_and_locales(self):
        fake, api, _, _, _ = self.prepared()
        bad = [("POST", "/v1/betaAppReviewSubmissions", {}),
               ("POST", "/v1/betaTesters", {}), ("PATCH", f"/v1/apps/{helper.APP_ID}", {}),
               ("GET", "https://api.appstoreconnect.apple.com/v1/builds", None),
               ("GET", "/v1/builds?filter%5Bapp%5D=another", None),
               ("POST", f"/v1/betaGroups/{helper.GROUP_ID}/relationships/builds",
                {"data": [{"type": "builds", "id": "wrong-build"}]}),
               ("POST", "/v1/betaBuildLocalizations", {"data": {"attributes": {"locale": "fr-FR"}}})]
        for old_build in ("7", "8", "9"):
            bad.append(("GET", "/v1/builds?" + urllib.parse.urlencode({"filter[app]": helper.APP_ID, "filter[version]": old_build, "include": "app,preReleaseVersion", "limit": "200"}), None))
        count = len(fake.calls)
        for method, path, payload in bad:
            with self.subTest(path=path), self.assertRaises(helper.GuardError):
                api.request(method, path, payload)
        self.assertEqual(len(fake.calls), count)
        readonly = helper.ScopedAPI(fake)
        readonly.build_id = BUILD_ID
        with self.assertRaises(helper.GuardError):
            readonly.request("POST", "/v1/betaBuildLocalizations", helper.localization_payload(BUILD_ID, "en-US"))

    def test_only_exact_two_notes_and_one_group_are_written_then_deduplicated(self):
        fake, api, summary, evidence, journal = self.prepared()
        result = helper.distribute(api, summary, evidence, journal)
        self.assertEqual(result["mutationCount"], 3)
        self.assertEqual(set(fake.locales), set(helper.NOTES))
        self.assertEqual(fake.members, [BUILD_ID])
        again = helper.distribute(api, summary, evidence, helper.Journal(journal.path, evidence))
        self.assertEqual(again["mutationCount"], 0)
        self.assertEqual(len([row for row in fake.calls if row[0] != "GET"]), 3)

    def test_existing_notes_update_by_scoped_id_and_unrelated_locale_is_untouched(self):
        fake, api, summary, evidence, journal = self.prepared()
        fake.locales = {"en-US": {"id": "old-en", "attributes": {"locale": "en-US", "whatsNew": "old"}},
                       "fr-FR": {"id": "old-fr", "attributes": {"locale": "fr-FR", "whatsNew": "untouched"}}}
        helper.distribute(api, summary, evidence, journal)
        self.assertEqual(fake.locales["fr-FR"]["attributes"]["whatsNew"], "untouched")
        self.assertEqual(fake.locales["en-US"]["attributes"]["whatsNew"], helper.NOTES["en-US"])
        self.assertEqual(len([row for row in fake.calls if row[0] == "PATCH"]), 1)
        with self.assertRaises(helper.GuardError):
            api.request("PATCH", "/v1/betaBuildLocalizations/old-en", helper.update_payload("old-en", "zh-Hans"))

    def test_unknown_accepted_post_is_reconciled_by_get_without_reposting(self):
        fake, api, summary, evidence, journal = self.prepared()
        fake.post_unknown = True
        result = helper.distribute(api, summary, evidence, journal)
        self.assertEqual(result["status"], "DISTRIBUTED_INTERNAL")
        state = json.loads(journal.path.read_text())
        self.assertTrue(all(value == "verified" for value in state["operations"].values()))
        helper.distribute(api, summary, evidence, helper.Journal(journal.path, evidence))
        posts = [row for row in fake.calls if row[0] == "POST" and row[1] == "/v1/betaBuildLocalizations"]
        self.assertEqual(len(posts), 2)  # Once per locale; first lost response was not repeated.

    def test_unknown_unaccepted_post_stays_pending_and_cannot_be_retried(self):
        fake, api, summary, evidence, journal = self.prepared()
        fake.post_unknown, fake.post_accepted = True, False
        with self.assertRaises(helper.GuardError):
            helper.distribute(api, summary, evidence, journal)
        with self.assertRaises(helper.GuardError):
            helper.distribute(api, summary, evidence, helper.Journal(journal.path, evidence))
        self.assertEqual(len([row for row in fake.calls if row[0] == "POST"]), 1)

    def test_empty_successful_group_response_is_get_reconciled_once(self):
        fake, api, summary, evidence, journal = self.prepared()
        fake.empty_group_response = True
        result = helper.distribute(api, summary, evidence, journal)
        self.assertEqual(result["status"], "DISTRIBUTED_INTERNAL")
        writes = [row for row in fake.calls if row[0] == "POST" and "/relationships/builds" in row[1]]
        self.assertEqual(len(writes), 1)
        self.assertEqual(json.loads(journal.path.read_text())["operations"]["group-build"], "verified")

    def test_journal_cannot_be_reused_for_another_ipa(self):
        _, _, _, evidence, journal = self.prepared()
        journal.save()
        with self.assertRaises(helper.GuardError):
            helper.Journal(journal.path, {**evidence, "ipaSHA256": "b" * 64})

    def test_journal_notes_identity_change_cannot_bypass_prior_pending_operation(self):
        identity = {**helper.scope(BUILD_ID), "notesSHA256": "a" * 64}
        path = self.directory / "notes-journal.json"
        journal = helper.Journal(path, identity)
        with self.assertRaises(helper.GuardError):
            journal.reconcile_or_issue("notes:zh-Hans:oldhash", lambda: False,
                                       lambda: (_ for _ in ()).throw(OSError("unknown")))
        with self.assertRaises(helper.GuardError):
            helper.Journal(path, {**identity, "notesSHA256": "b" * 64})

    def evidence_fixture(self):
        ipa = self.directory / "synthetic-identity-only.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/Test.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": helper.BUNDLE_ID,
                             "CFBundleShortVersionString": helper.VERSION, "CFBundleVersion": helper.BUILD}))
        audit = dict(status="PASS", appID=helper.APP_ID, bundleID=helper.BUNDLE_ID, marketingVersion=helper.VERSION,
                     buildNumber=helper.BUILD, ipaPath=str(ipa), ipaByteCount=ipa.stat().st_size,
                     ipaSHA256=hashlib.sha256(ipa.read_bytes()).hexdigest())
        approval = {**helper.scope(BUILD_ID), "approved": True, "action": "distribute-internal-build",
                    "ipaSHA256": audit["ipaSHA256"]}
        audit_path, approval_path = self.directory / "audit.json", self.directory / "approval.json"
        audit_path.write_text(json.dumps(audit))
        approval_path.write_text(json.dumps(approval))
        return ipa, audit, approval, audit_path, approval_path

    def test_distribution_requires_exact_ipa_bytes_plist_audit_and_approval(self):
        ipa, audit, approval, audit_path, approval_path = self.evidence_fixture()
        result = helper.validate_distribution_evidence(audit_path, approval_path, BUILD_ID)
        self.assertEqual(result["ipaSHA256"], audit["ipaSHA256"])
        for key, value in [("approved", False), ("buildID", "wrong"), ("groupID", "wrong"), ("ipaSHA256", "c" * 64),
                           ("buildNumber", "7"), ("buildNumber", "8"), ("buildNumber", "9")]:
            approval_path.write_text(json.dumps({**approval, key: value}))
            with self.assertRaises(helper.GuardError):
                helper.validate_distribution_evidence(audit_path, approval_path, BUILD_ID)
        approval_path.write_text(json.dumps(approval))
        audit_path.write_text(json.dumps({**audit, "status": "FAIL"}))
        with self.assertRaises(helper.GuardError):
            helper.validate_distribution_evidence(audit_path, approval_path, BUILD_ID)
        for old_build in ("7", "8", "9"):
            audit_path.write_text(json.dumps({**audit, "buildNumber": old_build}))
            with self.assertRaises(helper.GuardError):
                helper.validate_distribution_evidence(audit_path, approval_path, BUILD_ID)
        audit_path.write_text(json.dumps(audit))
        ipa.write_bytes(ipa.read_bytes() + b"changed")
        with self.assertRaises(helper.GuardError):
            helper.validate_distribution_evidence(audit_path, approval_path, BUILD_ID)

    def test_missing_distribution_approval_stops_before_authentication_or_api(self):
        with patch.object(helper, "trusted_transport") as transport, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.main(["--distribute", "--build-id", BUILD_ID]), 1)
            transport.assert_not_called()

    def test_unreviewed_jwt_source_is_rejected_before_auth_read(self):
        with patch.object(helper, "file_sha", return_value="changed"), patch.object(helper, "read_json") as read:
            with self.assertRaises(helper.GuardError):
                helper.trusted_transport(False)
            read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
