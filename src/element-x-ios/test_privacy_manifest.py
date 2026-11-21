"""Apply the CHIICH metadata overlay to the pinned upstream privacy manifest.

This checks the generated plist, not text fragments in the patch. Network and
native/runtime behavior are outside this offline test.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

import prepare


ROOT = Path(__file__).resolve().parent
TARGET = Path("ElementX/SupportingFiles/PrivacyInfo.xcprivacy")
FIXTURE = ROOT / "fixtures/privacy-manifest-upstream.plist"
UPSTREAM_SHA256 = "6bb07da3cbc10b2d8629abeb0c409cc1884a69ec17a86e921a10c0b9cd424274"


class PrivacyManifestTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), UPSTREAM_SHA256)
        self.upstream = plistlib.loads(FIXTURE.read_bytes())
        lock = json.loads((ROOT / "upstream.lock.json").read_text())
        overlays = [item for item in lock["patches"] if item["path"] == "patches/privacy-manifest.patch"]
        self.assertEqual(len(overlays), 1)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            target = source / TARGET
            target.parent.mkdir(parents=True)
            target.write_bytes(FIXTURE.read_bytes())
            prepare.apply(source, {"patches": overlays, "assets": []})
            self.manifest = plistlib.loads(target.read_bytes())

    def test_generated_manifest_links_server_persisted_data_to_accounts(self):
        entries = self.manifest["NSPrivacyCollectedDataTypes"]
        expected = {
            "Name", "EmailAddress", "Contacts", "EmailsOrTextMessages", "PhotosorVideos",
            "AudioData", "CustomerSupport", "OtherUserContent", "UserID", "DeviceID",
            "ProductInteraction", "OtherDiagnosticData",
        }
        self.assertEqual({item["NSPrivacyCollectedDataType"] for item in entries},
                         {"NSPrivacyCollectedDataType" + name for name in expected})
        self.assertEqual(len(entries), len(expected))
        for item in entries:
            self.assertIs(item["NSPrivacyCollectedDataTypeLinked"], True)
            self.assertIs(item["NSPrivacyCollectedDataTypeTracking"], False)
            self.assertEqual(item["NSPrivacyCollectedDataTypePurposes"],
                             ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])

    def test_overlay_preserves_required_reason_api_declarations(self):
        self.assertEqual(self.manifest["NSPrivacyAccessedAPITypes"],
                         self.upstream["NSPrivacyAccessedAPITypes"])
        self.assertIs(self.manifest["NSPrivacyTracking"], False)
        self.assertFalse(self.manifest.get("NSPrivacyTrackingDomains"))


if __name__ == "__main__":
    unittest.main()
