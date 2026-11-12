"""Offline activation boundaries. All IDs, profiles and gateway data are synthetic."""
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_signing import fixture, signing, trial_source

ROOT = Path(__file__).resolve().parent


def services(*, universal_links=False):
    return {
        "schema_version": 1, "mode": "services-enabled", "team_id": signing.TEAM,
        "bundle_id": signing.APP, "pusher_app_id": signing.APP + ".ios.prod",
        "apns_environment": "production", "gateway_base_url": "https://synthetic-push.onrender.com",
        "render_service_id": "srv-00000000000000000000", "gateway_ownership_verified": True,
        "universal_links": universal_links,
    }


def enabled_profile(target, config):
    profile = fixture(target)
    profile["Entitlements"].update(signing.required_capabilities(config)[target])
    return profile


def source_fixture(root):
    trial_source(root)
    (root / "CHIICH-SOURCE.json").write_bytes((ROOT / "upstream.lock.json").read_bytes())
    (root / "project.yml").write_text("include:\n# - path: MyAppVariant/override.yml\n")
    (root / "app.yml").write_text("settings:\n  BASE_BUNDLE_IDENTIFIER: one.chiich.app\n  APP_GROUP_IDENTIFIER: group.one.chiich\n")
    settings = root / "ElementX/Sources/Application/Settings/AppSettings.swift"
    settings.write_text(settings.read_text() + '\n    var pusherAppID: String {\n        #if DEBUG\n'
                        '        InfoPlistReader.main.baseBundleIdentifier + ".ios.dev"\n        #else\n'
                        '        InfoPlistReader.main.baseBundleIdentifier + ".ios.prod"\n        #endif\n    }\n')
    for target in signing.TARGETS:
        path = root / target / "SupportingFiles/target.yml"
        text = path.read_text() + "    info:\n      path: Info.plist\n      properties:\n"
        if target == "ElementX":
            text += "        # APNs and universal links are configured only with CHIICH-owned signing and services.\n"
        path.write_text(text)
    reader = root / "ElementX/Sources/Other/InfoPlistReader.swift"
    reader.parent.mkdir(parents=True)
    reader.write_text("var chiichPushGatewayBaseURL: URL?\n")
    coordinator = root / "ElementX/Sources/FlowCoordinators/OnboardingFlowCoordinator.swift"
    coordinator.parent.mkdir(parents=True)
    coordinator.write_text("!userSettings.app.hasRunNotificationPermissionsOnboarding && userSettings.account.enableNotifications\n")


def app_fixture(root, config=None, *, signed=True):
    app = root / "ElementX.app"
    for target, relative in (("ElementX", ""), ("NSE", "PlugIns/NSE.appex"), ("ShareExtension", "PlugIns/ShareExtension.appex")):
        path = app / relative
        path.mkdir(parents=True)
        info = {"CFBundleIdentifier": signing.TARGETS[target][0], "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "6"}
        if config is not None:
            info.update({signing.SERVICES_INFO_KEY: config, "baseBundleIdentifier": signing.APP,
                         "appGroupIdentifier": signing.GROUP,
                         "keychainAccessGroupIdentifier": (signing.TEAM if signed else "") + "." + signing.APP})
        (path / "Info.plist").write_bytes(plistlib.dumps(info))
    return app


def native_results(config, *, entitlement_mutation=None, profile_mutation=None):
    def run(args, label):
        if args[0] == "security":
            target = Path(args[-1]).parent.name
        else:
            if "--verify" in args:
                return b""
            target = Path(args[-1]).name
        target = {"ElementX.app": "ElementX", "NSE.appex": "NSE", "ShareExtension.appex": "ShareExtension"}[target]
        profile = enabled_profile(target, config)
        if args[0] == "security":
            if profile_mutation:
                profile_mutation(target, profile)
            # plist dates are naive UTC, as emitted by security cms.
            profile["ExpirationDate"] = profile["ExpirationDate"].replace(tzinfo=None)
            return plistlib.dumps(profile)
        ent = profile["Entitlements"]
        ent["keychain-access-groups"] = [signing.TEAM + "." + signing.APP]
        if entitlement_mutation:
            entitlement_mutation(target, ent)
        return plistlib.dumps(ent)
    return run


class ServicesConfigTests(unittest.TestCase):
    def test_default_trial_does_not_read_a_service_file(self):
        with patch.object(Path, "read_bytes", side_effect=AssertionError("Unexpected file access")):
            self.assertIsNone(signing.load_services(signing.TRIAL))
        with self.assertRaisesRegex(ValueError, "explicit services-enabled"):
            signing.load_services(signing.TRIAL, ROOT / "services.json")

    def test_example_is_intentionally_not_an_activation(self):
        with self.assertRaisesRegex(ValueError, "ownership"):
            signing.validate_services(json.loads((ROOT / "services.example.json").read_text()))

    def test_missing_unreviewed_duplicate_or_extra_fields_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "services.json"
            with patch.object(signing, "SERVICES_CONFIG", path):
                with self.assertRaisesRegex(ValueError, "reviewed services.json"):
                    signing.load_services(signing.SERVICES_ENABLED)
                path.write_text(json.dumps(services()))
                self.assertEqual(signing.load_services(signing.SERVICES_ENABLED), services())
                path.write_text(json.dumps(services())[:-1] + ', "mode": "services-enabled"}')
                with self.assertRaisesRegex(ValueError, "valid reviewed"):
                    signing.load_services(signing.SERVICES_ENABLED)
                path.write_text(" " * 4097)
                with self.assertRaises(ValueError):
                    signing.load_services(signing.SERVICES_ENABLED)
                alternative = Path(temp) / "alternative.json"
                alternative.write_text(json.dumps(services()))
                with self.assertRaisesRegex(ValueError, "reviewed src/"):
                    signing.load_services(signing.SERVICES_ENABLED, alternative)
                path.unlink()
                path.symlink_to(alternative)
                with self.assertRaisesRegex(ValueError, "reviewed src/"):
                    signing.load_services(signing.SERVICES_ENABLED)
        for key, value in (("schema_version", True), ("team_id", "OTHERTEAM00"),
                           ("bundle_id", "io.element.elementx"), ("pusher_app_id", "one.chiich.app.ios.dev"),
                           ("apns_environment", "development"), ("universal_links", "false"),
                           ("gateway_ownership_verified", 1), ("render_service_id", "unknown"),
                           ("secret", "synthetic-value")):
            config = services(); config[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError) as error:
                signing.validate_services(config)
            self.assertNotIn("synthetic-value", str(error.exception))

    def test_gateway_is_only_a_canonical_reviewed_render_origin(self):
        invalid = ["https://notifications.invalid", "https://matrix.org", "https://127.0.0.1", "https://chiich.one",
                   "http://synthetic-push.onrender.com", "https://synthetic-push.onrender.com/",
                   "https://synthetic-push.onrender.com/_matrix/push/v1/notify", "https://synthetic-push.onrender.com?x=1",
                   "https://synthetic-push.onrender.com#fragment", "https://u:p@synthetic-push.onrender.com",
                   "https://synthetic-push.onrender.com:443", "https://synthetic-push.onrender.com.evil.invalid",
                   "https://SYNTHETIC-push.onrender.com", "https://synthetic-push.onrender.com\n", "https://-bad.onrender.com"]
        for url in invalid:
            candidate = services(); candidate["gateway_base_url"] = url
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "canonical Render HTTPS origin"):
                signing.validate_services(candidate)

    def test_invalid_enabled_cli_stops_before_install_or_credential_access(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(signing, "SERVICES_CONFIG", Path(temp) / "services.json"), \
             patch.object(sys, "argv", ["signing", "install", "--source", temp, "--version", "1.0.0", "--build", "6",
                                       "--service-mode", "services-enabled"]), \
             patch.object(signing, "install") as install, patch.object(signing, "read_secret") as read_secret:
            with self.assertRaises(ValueError):
                signing.main()
            install.assert_not_called(); read_secret.assert_not_called()


class ServicesSourceTests(unittest.TestCase):
    def test_enabled_configuration_changes_metadata_and_capabilities_without_generating_swift(self):
        for links in (False, True):
            with self.subTest(universal_links=links), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); source_fixture(root)
                swift_before = {path: path.read_bytes() for path in root.rglob("*.swift")}
                signing.prepare_source(root, "1.0.0", "6", services=services(universal_links=links))
                self.assertEqual(swift_before, {path: path.read_bytes() for path in root.rglob("*.swift")})
                for target in signing.TARGETS:
                    text = (root / target / "SupportingFiles/target.yml").read_text()
                    self.assertEqual(text.count(signing.SERVICES_INFO_KEY + ":"), 1)
                    self.assertEqual("aps-environment: production" in text, target == "ElementX")
                    self.assertEqual("usernotifications.filtering: true" in text, target == "NSE")
                    self.assertEqual("applinks:chiich.one" in text, links and target == "ElementX")
                self.assertNotIn("secrets", (root / "chiich-signing.yml").read_text())

    def test_failed_preflight_does_not_partly_change_source(self):
        mutations = [("app.yml", "BASE_BUNDLE_IDENTIFIER: one.chiich.app", "BASE_BUNDLE_IDENTIFIER: io.element.elementx"),
                     ("ShareExtension/SupportingFiles/target.yml", "      properties:", "      unexpected:"),
                     ("NSE/SupportingFiles/target.yml", "entitlements:", "CHIICHNativeServices: {}\nentitlements:"),
                     ("ElementX/Sources/Application/Settings/AppSettings.swift", ' + ".ios.prod"', ' + ".ios.dev"')]
        for relative, before, after in mutations:
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); source_fixture(root)
                path = root / relative; path.write_text(path.read_text().replace(before, after))
                snapshot = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
                with self.assertRaises(ValueError):
                    signing.prepare_source(root, "1.0.0", "6", services=services())
                self.assertEqual(snapshot, {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()})


class ServicesSigningTests(unittest.TestCase):
    def test_enabled_profiles_require_own_production_capabilities(self):
        config = services(universal_links=True)
        for target in signing.TARGETS:
            signing.validate_profile(enabled_profile(target, config), target, services=config)
        for target, key, bad_value in (("ElementX", signing.APS, None), ("ElementX", signing.APS, "development"),
                                       ("NSE", signing.FILTERING, None), ("NSE", signing.FILTERING, 1),
                                       ("ElementX", signing.ASSOCIATED_DOMAINS, ["applinks:element.io"])):
            profile = enabled_profile(target, config)
            profile["Entitlements"][key] = bad_value
            with self.subTest(target=target, key=key), self.assertRaisesRegex(ValueError, "required entitlement"):
                signing.validate_profile(profile, target, services=config)

    def test_associated_domain_profile_accepts_apple_wildcard_forms(self):
        config = services(universal_links=True)
        for allowed in ("*", ["*"], ["applinks:chiich.one"]):
            profile = enabled_profile("ElementX", config)
            profile["Entitlements"][signing.ASSOCIATED_DOMAINS] = allowed
            with self.subTest(allowed=allowed):
                self.assertEqual(signing.validate_profile(profile, "ElementX", services=config)["bundle_id"], signing.APP)

    def test_associated_domain_profile_rejects_other_scalar_and_malformed_allowlists(self):
        config = services(universal_links=True)
        invalid = (None, True, False, 0, 1, "", "applinks:chiich.one", "applinks:*", "* ", b"*",
                   {"*": True}, [], ["applinks:other.invalid"], [True], ["*", True], ["applinks:chiich.one", 1])
        for allowed in invalid:
            profile = enabled_profile("ElementX", config)
            profile["Entitlements"][signing.ASSOCIATED_DOMAINS] = allowed
            with self.subTest(allowed=allowed), self.assertRaisesRegex(ValueError, "required entitlement com.apple.developer.associated-domains"):
                signing.validate_profile(profile, "ElementX", services=config)

    def test_signed_app_keeps_exact_domains_when_profile_uses_scalar_wildcard(self):
        config = services(universal_links=True)
        def wildcard_profile(target, profile):
            if target == "ElementX":
                profile["Entitlements"][signing.ASSOCIATED_DOMAINS] = "*"
        with tempfile.TemporaryDirectory() as temp:
            app = app_fixture(Path(temp), config)
            with patch.object(signing, "run", side_effect=native_results(config, profile_mutation=wildcard_profile)):
                signing.verify_app(app, "1.0.0", "6", services=config)
            for value in ("*", ["*"], "applinks:chiich.one", [], ["applinks:chiich.one", "applinks:other.invalid"],
                          ["applinks:chiich.one", "*"], 1):
                def wrong_signed_domains(target, ent):
                    if target == "ElementX":
                        ent[signing.ASSOCIATED_DOMAINS] = value
                with self.subTest(value=value), patch.object(signing, "run", side_effect=native_results(
                        config, profile_mutation=wildcard_profile, entitlement_mutation=wrong_signed_domains)), \
                     self.assertRaisesRegex(ValueError, "signed app lost required entitlement com.apple.developer.associated-domains"):
                    signing.verify_app(app, "1.0.0", "6", services=config)

    def test_unsigned_enabled_metadata_checks_use_the_unsigned_shared_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            config = services()
            app = app_fixture(Path(temp), config, signed=False)
            with patch.object(signing, "run") as native:
                signing.verify_app(app, "1.0.0", "6", signed=False, services=config)
                native.assert_not_called()
                with self.assertRaisesRegex(ValueError, "trial policy"):
                    signing.verify_app(app, "1.0.0", "6", signed=False)

    def test_signed_app_revalidates_embedded_profiles_and_exact_target_entitlements(self):
        config = services(universal_links=True)
        with tempfile.TemporaryDirectory() as temp:
            app = app_fixture(Path(temp), config)
            with patch.object(signing, "run", side_effect=native_results(config)) as native:
                signing.verify_app(app, "1.0.0", "6", services=config)
                self.assertEqual(sum(call.args[0][0] == "security" for call in native.call_args_list), 3)
            for target, key, value in (("ElementX", signing.APS, "development"), ("NSE", signing.FILTERING, False),
                                       ("ElementX", signing.ASSOCIATED_DOMAINS, ["*"]),
                                       ("ShareExtension", signing.APS, "production"),
                                       ("ShareExtension", signing.FILTERING, True),
                                       ("NSE", signing.ASSOCIATED_DOMAINS, ["applinks:chiich.one"])):
                def mutate(current, ent):
                    if current == target:
                        ent[key] = value
                with self.subTest(target=target, key=key), patch.object(signing, "run", side_effect=native_results(config, entitlement_mutation=mutate)), self.assertRaises(ValueError):
                    signing.verify_app(app, "1.0.0", "6", services=config)
            def wrong_profile(target, profile):
                if target == "NSE":
                    profile["Entitlements"].pop(signing.FILTERING)
            with patch.object(signing, "run", side_effect=native_results(config, profile_mutation=wrong_profile)), self.assertRaisesRegex(ValueError, "required entitlement"):
                signing.verify_app(app, "1.0.0", "6", services=config)
            other_config = services(universal_links=True); other_config["gateway_base_url"] = "https://other-synthetic.onrender.com"
            with patch.object(signing, "run", side_effect=native_results(config)), self.assertRaisesRegex(ValueError, "reviewed configuration"):
                signing.verify_app(app, "1.0.0", "6", services=other_config)

    def test_package_provenance_cannot_change_mode_gateway_or_digest(self):
        for config in (None, services()):
            with self.subTest(mode=bool(config)), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); export = root / "export"; export.mkdir()
                payload = b"synthetic-package-only"
                (export / "native.ipa").write_bytes(payload)
                output = root / "distribution"
                with patch.object(signing, "verify_ipa") as verify:
                    signing.package(export, output, "1.0.0", "6", "a" * 40, services=config)
                    verify.assert_called_once_with(export / "native.ipa", "1.0.0", "6", services=config)
                    signing.verify_package(output, "1.0.0", "6", "a" * 40, services=config)
                    receipt = json.loads((output / "provenance.json").read_text())
                    self.assertEqual(receipt["ipa_sha256"], hashlib.sha256(payload).hexdigest())
                    if config is None:
                        self.assertNotIn("native_services", receipt)
                        self.assertEqual(receipt["push_notifications"], "disabled-trial")
                    else:
                        self.assertEqual(receipt["native_services"], config)
                    with self.assertRaisesRegex(ValueError, "reviewed CHIICH source"):
                        signing.verify_package(output, "1.0.0", "6", "a" * 40, services=services() if config is None else None)
                    if config is not None:
                        modified = copy.deepcopy(config); modified["gateway_base_url"] = "https://other-synthetic.onrender.com"
                        with self.assertRaisesRegex(ValueError, "reviewed CHIICH source"):
                            signing.verify_package(output, "1.0.0", "6", "a" * 40, services=modified)
                        malformed_receipt = copy.deepcopy(receipt)
                        malformed_receipt["native_services"]["gateway_ownership_verified"] = 1
                        (output / "provenance.json").write_text(json.dumps(malformed_receipt))
                        with self.assertRaisesRegex(ValueError, "ownership"):
                            signing.verify_package(output, "1.0.0", "6", "a" * 40, services=config)
                        (output / "provenance.json").write_text(json.dumps(receipt))
                    (output / "CHIICH.ipa").write_bytes(b"changed")
                    with self.assertRaisesRegex(ValueError, "digest"):
                        signing.verify_package(output, "1.0.0", "6", "a" * 40, services=config)


class WorkflowServicesTests(unittest.TestCase):
    def test_device_boundaries_share_one_mode_and_gate_precedes_credentials(self):
        text = (ROOT.parent.parent / ".github/workflows/chiich-ios-device.yml").read_text()
        self.assertIn("default: disabled-trial", text)
        self.assertLess(text.index("signing.py check-services"), text.index("environment: chiich-ios-signing"))
        for line in text.splitlines():
            if any("signing.py " + command + " " in line for command in ("unsigned", "install", "verify", "package", "verify-package")):
                self.assertIn('--service-mode "$CHIICH_SERVICE_MODE"', line)
        upload_job = text[text.index("  testflight-upload:\n"):]
        self.assertLess(upload_job.index("signing.py verify-package"), upload_job.index("CHIICH_ASC_PRIVATE_KEY_P8:"))
        simulator = (ROOT.parent.parent / ".github/workflows/chiich-ios.yml").read_text()
        self.assertIn("-only-testing:UnitTests/CHIICHNativeServicesTests", simulator)


if __name__ == "__main__":
    unittest.main()
