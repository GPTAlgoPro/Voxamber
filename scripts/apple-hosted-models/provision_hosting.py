#!/usr/bin/env python3
"""Register only Voxamber's downloader ID and APP_GROUPS capabilities.

App-group registration/association is not exposed by Apple's current OpenAPI
4.6. This helper reports the actual API availability; it never uses private
cookie-authenticated endpoints or substitutes an unverified association.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import urllib.parse

from upload_model import API, APIError, APP_ID, BUNDLE_ID, ROOT, UploadError, require

EXTENSION_ID = "com.kaisun.voxamber.model-downloader"
GROUP_ID = "group.com.kaisun.voxamber.background-assets"
TEAM = "M97RTV2PQG"


def bundle(api, identifier, name, create):
    path = "/v1/bundleIds?" + urllib.parse.urlencode({"filter[identifier]": identifier})
    # Apple's identifier filter may also return child bundle identifiers.
    rows = [r for r in api.rows(path) if r.get("attributes", {}).get("identifier") == identifier]
    if not rows and create:
        api.request("POST", "/v1/bundleIds", {"data": {"type": "bundleIds",
            "attributes": {"name": name, "identifier": identifier, "platform": "IOS"}}})
        rows = [r for r in api.rows(path) if r.get("attributes", {}).get("identifier") == identifier]
    require(len(rows) == 1 and rows[0]["attributes"].get("identifier") == identifier
            and rows[0]["attributes"].get("seedId") == TEAM, "Exact Voxamber bundle/team identity check failed")
    return rows[0]


def capability(api, item, create):
    # Omit the optional limit: this account's endpoint rejects limit=200 with
    # HTTP 400 although the public schema documents it. The small collection
    # is still fully paginated by API.rows if Apple returns a next link.
    path = "/v1/bundleIds/" + item["id"] + "/bundleIdCapabilities"
    matches = [r for r in api.rows(path) if r.get("attributes", {}).get("capabilityType") == "APP_GROUPS"]
    require(len(matches) <= 1, "Ambiguous APP_GROUPS capability")
    if not matches and create:
        api.request("POST", "/v1/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities", "attributes": {"capabilityType": "APP_GROUPS"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": item["id"]}}}}})
        matches = [r for r in api.rows(path) if r.get("attributes", {}).get("capabilityType") == "APP_GROUPS"]
    return {"identifier": item["attributes"]["identifier"], "bundleRecordID": item["id"],
        "capabilityRecordID": matches[0]["id"] if len(matches) == 1 else None,
        "appGroupsCapabilityPresent": len(matches) == 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--key-path", required=True, type=Path)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    api = API(args.key_id, args.issuer, args.key_path, allow_upload=args.execute)
    api.verify_target()
    receipt = {"appID": APP_ID, "bundleID": BUNDLE_ID, "extensionBundleID": EXTENSION_ID,
        "appGroupIdentifier": GROUP_ID, "observedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "appGroupAssociationsVerified": False, "projectSettingsModified": False}
    try:
        main = bundle(api, BUNDLE_ID, "Voxamber", False)
        extension = bundle(api, EXTENSION_ID, "Voxamber Model Downloader", args.execute)
        receipt["bundles"] = [capability(api, main, args.execute), capability(api, extension, args.execute)]
        try:
            rows = api.rows("/v1/appGroups?" + urllib.parse.urlencode({"filter[identifier]": GROUP_ID, "limit": "200"}))
            receipt["appGroupsAPIHTTPStatus"] = 200
            receipt["matchingAppGroupCount"] = len(rows)
        except APIError as error:
            receipt["appGroupsAPIHTTPStatus"] = error.status
        receipt["capabilitiesVerified"] = all(r["appGroupsCapabilityPresent"] for r in receipt["bundles"])
    except (APIError, UploadError) as error:
        receipt["diagnostic"] = str(error)
    output = ROOT / "Apple/AssetPacks/hosting-provisioning-receipt.json"
    output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps(receipt, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
