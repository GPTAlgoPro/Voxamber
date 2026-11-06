# Scene-source TestFlight 8 helper

This host-only helper is restricted to Voxamber `com.kaisun.voxamber`, App Store
Connect app `6831042755`, iOS `0.2.0 (8)`, and the existing private internal group
`7d4c4aba-14b9-423e-b1ae-d50ce983d527`. It does not upload an IPA, invite a tester,
submit beta/App Store review, change app metadata, or release a public version.
No helper action changes Git branches.

## Read-only preflight

Run from the repository root, only when authorized to access App Store Connect:

```sh
python3 scripts/app-release/scene_testflight.py
```

The default permits GET only. It verifies the app bundle ID, private internal
group and its app owner, exactly one existing tester via relationship IDs only,
build number, prerelease version/platform, processing state, beta state, expiry,
and existing group/build membership. It never fetches tester records, names,
emails, or contact attributes. Output contains only scoped IDs, anonymous count,
and readiness. A build not yet uploaded produces `BUILD_NOT_FOUND`; this is not
TestFlight availability. `READY` requires `VALID`, not expired, and an internal
state of `READY_FOR_BETA_TESTING` or `IN_BETA_TESTING`. New/unknown states stop
distribution rather than being assumed safe.

Authentication is read only from the ignored file
`Apple/.build/scene-testflight7/auth-config.private.json`, keys `key_id`, `issuer`,
and `key_path`. Its values and the signing key never belong in Git or receipts.
Before reading it, the helper verifies that the existing JWT transport source
`scripts/apple-hosted-models/upload_model.py` has SHA256
`f04e87d475c043551a6b395dda1001ce3716852c7ec2e7ebc8067a1d1f4f8089`.
The transport refuses a private key inside the repository. No authentication
values or raw HTTP errors are printed.

## Future explicit internal distribution

Preparation and mocked tests do not authorize this action. The release owner
must first finish the actual IPA audit/upload, obtain the actual ASC build ID,
and authorize internal distribution. Use two local ignored evidence files.

The audit JSON must contain the following exact field names/types (additional
provenance fields are allowed):

```json
{
  "status": "PASS",
  "appID": "6831042755",
  "bundleID": "com.kaisun.voxamber",
  "marketingVersion": "0.2.0",
  "buildNumber": "8",
  "ipaPath": "/absolute/path/to/the-actual-audited.ipa",
  "ipaByteCount": 123,
  "ipaSHA256": "actual-lowercase-64-hex-sha256"
}
```

The separate approval JSON must use these exact scope fields. The release owner
sets `approved` to true only after actual approval; this template is deliberately
not an approval:

```json
{
  "approved": false,
  "action": "distribute-internal-build",
  "appID": "6831042755",
  "bundleID": "com.kaisun.voxamber",
  "marketingVersion": "0.2.0",
  "buildNumber": "8",
  "buildID": "actual-ASC-build-ID",
  "groupID": "7d4c4aba-14b9-423e-b1ae-d50ce983d527",
  "ipaSHA256": "actual-lowercase-64-hex-sha256"
}
```

Only after approval:

```sh
python3 scripts/app-release/scene_testflight.py \
  --distribute --build-id ACTUAL_ASC_BUILD_ID \
  --audit Apple/.build/scene-testflight8/ipa-audit.private.json \
  --approval Apple/.build/scene-testflight8/distribution-approval.private.json
```

Before authenticating, the helper hashes the actual IPA, checks its byte count,
reads its unique main bundle Info.plist, and verifies its identity against the
audit and approval. It then independently checks the remote build identity and
readiness. The audit document is the release owner's verification assertion;
these identity checks do not replace a signature, entitlement, payload, or
real-device audit.

The only permitted mutations are the fixed `zh-Hans`/`en-US` beta `whatsNew`
strings and adding this one build to this one existing group. Notes accurately
describe scene-source import from the user's own AI app, `.js`/`.txt`/`.html`
and paste, local compilation without a model download, preserved read-only
legacy projects, no remote conversation-URL fetching, and incomplete complex
scene coverage. They make no claim of on-device AI generation.

Every mutation has a durable pending journal entry before its one attempt.
GET confirms desired state before any write and after it. A lost response or an
empty successful 204 is reconciled by GET, never by re-POSTing. If GET cannot
confirm the result, the journal stays pending and subsequent runs refuse that
mutation. After process interruption, the same approved command can only
reconcile an existing pending entry; it cannot repeat an unconfirmed mutation.
Do not delete or reset the journal to bypass uncertainty. IPA/build or notes
changes invalidate its identity. A local file lock prevents concurrent runs.

`DISTRIBUTED_INTERNAL` means both notes and group membership were read back.
It does not prove device installation, human testing, public review, or release.

## Offline tests

```sh
python3 -m unittest discover -s scripts/app-release -p test_scene_testflight.py -v
```

These tests use fake ASC responses, block real HTTP opening, and create small
synthetic ZIP/plist fixtures only to exercise evidence guards. They are not a
real IPA audit, Apple processing check, or TestFlight distribution receipt.

The existing scene-testflight7 authentication pointer is build-independent. Build8 distribution uses a separate scene-testflight8 journal and fresh actual audit/approval; it cannot resume build7 distribution.
