"""Offline signing boundary tests; no real certificates, Apple APIs or Xcode."""
import copy
import base64
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("chiich_signing", ROOT / "signing.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


def fixture(target="ElementX"):
    return {
        "TeamIdentifier": [signing.TEAM], "ApplicationIdentifierPrefix": [signing.TEAM],
        "UUID": "11111111-2222-3333-4444-555555555555",
        "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
        "DeveloperCertificates": [b"synthetic-certificate-only"],
        "Entitlements": {
            "application-identifier": signing.TEAM + "." + signing.TARGETS[target][0],
            "com.apple.developer.team-identifier": signing.TEAM,
            "get-task-allow": False, "beta-reports-active": True,
            "keychain-access-groups": [signing.TEAM + ".*"],
            "com.apple.security.application-groups": [signing.GROUP],
            **signing.CAPABILITIES[target],
        },
    }


def trial_source(root):
    (root / "ElementX/SupportingFiles").mkdir(parents=True)
    (root / "ElementX/SupportingFiles/target.yml").write_text("entitlements:\n")
    settings = root / "ElementX/Sources/Application/Settings"; settings.mkdir(parents=True)
    (settings / "AppSettings.swift").write_text(signing.GATEWAY_DECLARATION + "\n" + signing.ONBOARDING_PREFERENCE)
    (settings / "AccountSettings.swift").write_text(signing.ACCOUNT_PREFERENCE)
    (root / "NSE/SupportingFiles").mkdir(parents=True)
    (root / "NSE/SupportingFiles/target.yml").write_text("entitlements:\n        com.apple.developer.usernotifications.filtering: true\n")
    (root / "ShareExtension/SupportingFiles").mkdir(parents=True)
    (root / "ShareExtension/SupportingFiles/target.yml").write_text("entitlements:\n")


class ProfileTests(unittest.TestCase):
    def test_correct_distribution_profiles_for_each_target(self):
        for target in signing.TARGETS:
            with self.subTest(target=target):
                self.assertEqual(signing.validate_profile(fixture(target), target)["bundle_id"], signing.TARGETS[target][0])

    def test_expired_profile(self):
        profile = fixture()
        profile["ExpirationDate"] = datetime.now(timezone.utc) - timedelta(seconds=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            signing.validate_profile(profile, "ElementX")

    def test_profile_for_other_team_or_app_rejected(self):
        for key, value in (("TeamIdentifier", ["OTHERTEAM00"]), ("ApplicationIdentifierPrefix", ["OTHERTEAM00"])):
            profile = fixture(); profile[key] = value
            with self.assertRaisesRegex(ValueError, "different Apple team"):
                signing.validate_profile(profile, "ElementX")
        profile = fixture("ShareExtension")
        with self.assertRaisesRegex(ValueError, "does not match"):
            signing.validate_profile(profile, "ElementX")

    def test_device_development_and_enterprise_profiles_rejected(self):
        for mutation in (lambda p: p.update(ProvisionedDevices=[]), lambda p: p.update(ProvisionsAllDevices=True),
                         lambda p: p["Entitlements"].update({"get-task-allow": True})):
            profile = fixture(); mutation(profile)
            with self.assertRaisesRegex(ValueError, "App Store distribution"):
                signing.validate_profile(profile, "ElementX")

    def test_missing_shared_group_or_keychain_rejected(self):
        for key in ("com.apple.security.application-groups", "keychain-access-groups"):
            profile = fixture(); profile["Entitlements"][key] = []
            with self.assertRaises(ValueError):
                signing.validate_profile(profile, "ElementX")

    def test_explicit_push_disabled_trial_does_not_require_unused_filtering(self):
        profile = fixture("NSE")
        self.assertNotIn("com.apple.developer.usernotifications.filtering", profile["Entitlements"])
        signing.validate_profile(profile, "NSE")

    def test_missing_testflight_capability(self):
        profile = fixture(); profile["Entitlements"].pop("beta-reports-active")
        with self.assertRaisesRegex(ValueError, "TestFlight"):
            signing.validate_profile(profile, "ElementX")

    def test_profile_uuid_is_not_a_path(self):
        profile = fixture(); profile["UUID"] = "../../unrelated"
        with self.assertRaisesRegex(ValueError, "UUID"):
            signing.validate_profile(profile, "ElementX")


class ConfigurationTests(unittest.TestCase):
    def test_no_credentials_in_unsigned_source_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            trial_source(root)
            (root / "CHIICH-SOURCE.json").write_bytes((ROOT / "upstream.lock.json").read_bytes())
            (root / "project.yml").write_text("settings:\n  MARKETING_VERSION: 26.10.8\n  CURRENT_PROJECT_VERSION: 1\ninclude:\n# - path: MyAppVariant/override.yml\n")
            signing.prepare_source(root, "0.1.0", "2026.11.2")
            config = json.loads((root / "chiich-signing.yml").read_text())
            self.assertNotIn("settings", config)
            for target in signing.TARGETS:
                self.assertEqual(config["targets"][target]["settings"]["base"], {"MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "2026.11.2"})
            self.assertIn("- path: chiich-signing.yml", (root / "project.yml").read_text())
            self.assertNotIn("usernotifications.filtering", (root / "NSE/SupportingFiles/target.yml").read_text())

    def test_each_target_receives_its_own_profile(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            trial_source(root)
            (root / "CHIICH-SOURCE.json").write_bytes((ROOT / "upstream.lock.json").read_bytes())
            (root / "project.yml").write_text("include:\n# - path: MyAppVariant/override.yml\n")
            profiles = {target: {"uuid": str(index)} for index, target in enumerate(signing.TARGETS)}
            signing.prepare_source(root, "0.1.0", "1", profiles, "SYNTHETIC_FINGERPRINT")
            config = json.loads((root / "chiich-signing.yml").read_text())
            self.assertEqual(config["settings"]["DEVELOPMENT_TEAM"], signing.TEAM)
            self.assertEqual(len({v["settings"]["base"]["PROVISIONING_PROFILE_SPECIFIER"] for v in config["targets"].values()}), 3)
            self.assertNotIn("PROVISIONING_PROFILE_SPECIFIER", config["settings"])

    def test_unexpected_source_is_not_modified(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "CHIICH-SOURCE.json").write_text("{}")
            (root / "project.yml").write_text("unchanged")
            with self.assertRaisesRegex(ValueError, "current pinned"):
                signing.prepare_source(root, "0.1.0", "1")
            self.assertEqual((root / "project.yml").read_text(), "unchanged")

    def test_trial_refuses_to_strip_filtering_if_push_was_enabled(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); trial_source(root)
            (root / "CHIICH-SOURCE.json").write_bytes((ROOT / "upstream.lock.json").read_bytes())
            (root / "project.yml").write_text("include:\n# - path: MyAppVariant/override.yml\n")
            (root / "ElementX/SupportingFiles/target.yml").write_text("aps-environment: production\n")
            with self.assertRaisesRegex(ValueError, "push-disabled trial"):
                signing.prepare_source(root, "0.1.0", "1")
            self.assertIn("usernotifications.filtering", (root / "NSE/SupportingFiles/target.yml").read_text())

    def test_version_and_build_are_bounded_values(self):
        for version, build in (("0.1.0; echo bad", "1"), ("1.0", "1"), ("0.1.0", "10000"), ("0.1.0", "1.100.1"), ("0.1.0", "$(whoami)")):
            with self.assertRaises(ValueError):
                signing.validate_version(version, build)
        signing.validate_version("0.1.0", "2026.11.2")


class HandlingTests(unittest.TestCase):
    PEM = b"-----BEGIN PRIVATE KEY-----\nc3ludGhldGljLWZpeHR1cmUtb25seQ==\n-----END PRIVATE KEY-----\n"

    def test_raw_upload_key_normalizes_lf_and_crlf(self):
        for value in (self.PEM.decode(), "  " + self.PEM.decode().replace("\n", "\r\n") + "  "):
            with patch.dict(os.environ, {"CHIICH_ASC_PRIVATE_KEY_P8": value}, clear=True):
                self.assertEqual(signing.read_upload_key(), self.PEM)
                self.assertNotIn("CHIICH_ASC_PRIVATE_KEY_P8", os.environ)

    def test_raw_key_precedence_and_both_secrets_removed(self):
        with patch.dict(os.environ, {"CHIICH_ASC_PRIVATE_KEY_P8": self.PEM.decode(), "CHIICH_ASC_PRIVATE_KEY_P8_BASE64": "unused-invalid"}, clear=True):
            self.assertEqual(signing.read_upload_key(), self.PEM)
            self.assertFalse(any(name in os.environ for name in signing.ASC_KEY_SECRETS))

    def test_base64_upload_key_fallback(self):
        with patch.dict(os.environ, {"CHIICH_ASC_PRIVATE_KEY_P8": "\n", "CHIICH_ASC_PRIVATE_KEY_P8_BASE64": base64.b64encode(self.PEM).decode()}, clear=True):
            self.assertEqual(signing.read_upload_key(), self.PEM)

    def test_invalid_raw_key_does_not_fallback_or_echo_content(self):
        for value in ("secret-marker", self.PEM.decode() * 2, self.PEM.decode().replace("PRIVATE KEY", "ENCRYPTED PRIVATE KEY"), self.PEM.decode().replace("\n", r"\n"), self.PEM.decode().replace("c3ludGhldGljLWZpeHR1cmUtb25seQ==", "???"), "x" * 16385):
            with self.subTest(value_kind=len(value)), patch.dict(os.environ, {"CHIICH_ASC_PRIVATE_KEY_P8": value, "CHIICH_ASC_PRIVATE_KEY_P8_BASE64": base64.b64encode(self.PEM).decode()}, clear=True):
                with self.assertRaises(ValueError) as error:
                    signing.read_upload_key()
                self.assertEqual(str(error.exception), "CHIICH_ASC_PRIVATE_KEY_P8 must contain one unencrypted PKCS#8 PRIVATE KEY PEM file")
                self.assertFalse(any(name in os.environ for name in signing.ASC_KEY_SECRETS))

    def test_missing_and_invalid_base64_key_errors_are_bounded(self):
        for environment in ({}, {"CHIICH_ASC_PRIVATE_KEY_P8_BASE64": "secret-marker!"}):
            with patch.dict(os.environ, environment, clear=True), self.assertRaises(ValueError) as error:
                signing.read_upload_key()
            self.assertNotIn("secret-marker", str(error.exception))

    def test_failed_apple_validation_deletes_key_and_does_not_upload(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {"RUNNER_TEMP": temp, "CHIICH_ASC_PRIVATE_KEY_P8": self.PEM.decode()}, clear=True):
            def fail_validation(args, label):
                key = signing.state_path() / "private_keys/AuthKey_ABCDEFGHIJ.p8"
                self.assertEqual(key.read_bytes(), self.PEM)
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertIn("--validate-app", args)
                raise ValueError("synthetic validation failure")
            with patch.object(signing, "run", side_effect=fail_validation) as native, self.assertRaisesRegex(ValueError, "synthetic validation failure"):
                signing.upload(Path("synthetic.ipa"), "1.0.0", "1", "6829606447", "ABCDEFGHIJ", "11111111-2222-3333-4444-555555555555")
            self.assertEqual(native.call_count, 1)
            self.assertFalse((signing.state_path() / "private_keys/AuthKey_ABCDEFGHIJ.p8").exists())

    def test_unsigned_archive_checks_actual_version_for_all_targets(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "ElementX.app"
            for target, relative in (("ElementX", ""), ("NSE", "PlugIns/NSE.appex"), ("ShareExtension", "PlugIns/ShareExtension.appex")):
                path = app / relative; path.mkdir(parents=True, exist_ok=True)
                (path / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": signing.TARGETS[target][0], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2"}))
            with patch.object(signing, "run") as native:
                signing.verify_app(app, "0.1.0", "2", signed=False)
                native.assert_not_called()
                info = app / "PlugIns/NSE.appex/Info.plist"
                data = plistlib.loads(info.read_bytes()); data["CFBundleShortVersionString"] = "26.10.8"; info.write_bytes(plistlib.dumps(data))
                with self.assertRaisesRegex(ValueError, "NSE: unexpected release version"):
                    signing.verify_app(app, "0.1.0", "2", signed=False)

    def test_native_tool_failure_does_not_expose_secrets(self):
        result = subprocess.CompletedProcess([], 1, b"", b"secret-value-in-error")
        with patch.object(signing.subprocess, "run", return_value=result), self.assertRaises(ValueError) as error:
            signing.run(["security", "-p", "secret-value-in-command"], "Test operation")
        self.assertNotIn("secret-value", str(error.exception))

    def test_secret_environment_not_inherited_by_native_tools(self):
        with patch.dict(os.environ, {"CHIICH_IOS_DISTRIBUTION_P12_PASSWORD": "synthetic", "CHIICH_ASC_PRIVATE_KEY_P8_BASE64": "synthetic", "CHIICH_ASC_PRIVATE_KEY_P8": "synthetic"}), patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"", b"")) as mocked:
            signing.run(["security"], "Test")
        environment = mocked.call_args.kwargs["env"]
        self.assertNotIn("CHIICH_IOS_DISTRIBUTION_P12_PASSWORD", environment)
        self.assertNotIn("CHIICH_ASC_PRIVATE_KEY_P8_BASE64", environment)
        self.assertNotIn("CHIICH_ASC_PRIVATE_KEY_P8", environment)

    def test_wrong_source_and_modified_ipa_fail_before_verification(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / "CHIICH.ipa").write_bytes(b"synthetic")
            receipt = {"source_sha": "a" * 40, "version": "0.1.0", "build": "1", "app_id": "6829606447",
                       "bundle_id": signing.APP, "team_id": signing.TEAM, "ipa_sha256": "wrong",
                       "push_notifications": "disabled-trial", "nse_filtering": "omitted-unused-entitlement"}
            (path / "provenance.json").write_text(json.dumps(receipt))
            with patch.object(signing, "verify_ipa") as verify:
                with self.assertRaisesRegex(ValueError, "reviewed CHIICH source"):
                    signing.verify_package(path, "0.1.0", "1", "b" * 40)
                with self.assertRaisesRegex(ValueError, "digest"):
                    signing.verify_package(path, "0.1.0", "1", "a" * 40)
                verify.assert_not_called()

    def test_cleanup_attempts_profile_removal_even_if_keychain_restoration_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); state = root / "chiich-ios-signing"; state.mkdir()
            profiles = root / "profiles"; profiles.mkdir()
            profile = profiles / "11111111-2222-3333-4444-555555555555.mobileprovision"; profile.write_text("synthetic")
            (state / "cleanup.json").write_text(json.dumps({"previous_keychains": [], "profiles": [str(profile)]}))
            with patch.dict(os.environ, {"RUNNER_TEMP": str(root)}), patch.object(signing, "PROFILE_DIR", profiles), patch.object(signing, "run", side_effect=ValueError("synthetic")):
                with self.assertRaisesRegex(ValueError, "Cleanup incomplete"):
                    signing.cleanup()
            self.assertFalse(profile.exists())
            self.assertFalse(state.exists())


if __name__ == "__main__":
    unittest.main()
