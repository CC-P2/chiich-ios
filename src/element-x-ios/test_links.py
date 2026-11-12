"""Links-only release boundaries, with synthetic profiles and HTTP responses."""
import copy
from email.message import Message
import hashlib
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from test_signing import fixture, signing
from test_services import app_fixture, enabled_profile, native_results, services, source_fixture


def links():
    return signing.load_services(signing.LINKS_ONLY)


def links_app(root):
    app = app_fixture(root, links())
    for path in (app / "Info.plist", app / "PlugIns/NSE.appex/Info.plist", app / "PlugIns/ShareExtension.appex/Info.plist"):
        info = plistlib.loads(path.read_bytes())
        info.pop(signing.SERVICES_INFO_KEY)
        path.write_bytes(plistlib.dumps(info))
    return app


def response(payload=None, *, content_type="application/json", status=200, url=None):
    result = Mock()
    result.__enter__ = Mock(return_value=result)
    result.__exit__ = Mock(return_value=None)
    result.getcode.return_value = status
    result.geturl.return_value = url or signing.ASSOCIATION_URL
    result.headers = Message()
    if content_type is not None:
        result.headers["Content-Type"] = content_type
    result.read.return_value = payload if payload is not None else signing.ASSOCIATION_FIXTURE.read_bytes()
    return result


class LinksOnlyPolicyTests(unittest.TestCase):
    def test_mode_is_an_explicit_fixed_identity_without_gateway_or_file_override(self):
        with patch.object(Path, "read_bytes", side_effect=AssertionError("No service-file lookup")):
            config = links()
        self.assertEqual(config, {"schema_version": 1, "mode": "links-only", "team_id": signing.TEAM,
                                  "bundle_id": signing.APP, "universal_links": True})
        with self.assertRaises(ValueError):
            signing.load_services(signing.LINKS_ONLY, Path("services.json"))
        for key, value in (("schema_version", True), ("team_id", "OTHERTEAM00"),
                           ("universal_links", 1), ("universal_links", False),
                           ("gateway_base_url", "https://synthetic-push.onrender.com")):
            candidate = dict(config); candidate[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                signing.validate_services(candidate)

    def test_links_source_keeps_push_off_and_changes_only_main_domain_entitlement(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source_fixture(root)
            swift_before = {p: p.read_bytes() for p in root.rglob("*.swift")}
            signing.prepare_source(root, "1.0.0", "6", services=links())
            self.assertEqual(swift_before, {p: p.read_bytes() for p in root.rglob("*.swift")})
            for target in signing.TARGETS:
                text = (root / target / "SupportingFiles/target.yml").read_text()
                self.assertNotIn("aps-environment:", text)
                self.assertNotIn("usernotifications.filtering:", text)
                self.assertNotIn(signing.SERVICES_INFO_KEY, text)
                self.assertEqual("applinks:chiich.one" in text, target == "ElementX")

    def test_links_preflight_rejects_changed_app_identity_without_partial_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source_fixture(root)
            path = root / "app.yml"
            path.write_text(path.read_text().replace(signing.APP, "io.element.elementx"))
            snapshot = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            with self.assertRaisesRegex(ValueError, "application identifiers"):
                signing.prepare_source(root, "1.0.0", "6", services=links())
            self.assertEqual(snapshot, {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()})

    def test_existing_nse_profile_is_accepted_only_when_push_remains_off(self):
        signing.validate_profile(fixture("NSE"), "NSE", services=links())
        with self.assertRaisesRegex(ValueError, "required entitlement"):
            signing.validate_profile(fixture("NSE"), "NSE", services=services())
        for allowed in ("*", ["*"], ["applinks:chiich.one"]):
            profile = fixture("ElementX")
            profile["Entitlements"][signing.ASSOCIATED_DOMAINS] = allowed
            signing.validate_profile(profile, "ElementX", services=links())
        with self.assertRaisesRegex(ValueError, "required entitlement"):
            signing.validate_profile(fixture("ElementX"), "ElementX", services=links())

    def test_signed_links_archive_requires_exact_domain_and_rejects_every_push_leak(self):
        config = links()
        with tempfile.TemporaryDirectory() as temp:
            app = links_app(Path(temp))
            with patch.object(signing, "run", side_effect=native_results(config)) as native:
                signing.verify_app(app, "1.0.0", "6", services=config)
                self.assertEqual(sum(call.args[0][0] == "security" for call in native.call_args_list), 3)
            invalid = [("ElementX", signing.ASSOCIATED_DOMAINS, ["*"]),
                       ("ElementX", signing.ASSOCIATED_DOMAINS, ["applinks:other.invalid"]),
                       ("ElementX", signing.APS, "production"), ("NSE", signing.FILTERING, True),
                       ("NSE", signing.ASSOCIATED_DOMAINS, ["applinks:chiich.one"]),
                       ("ShareExtension", signing.ASSOCIATED_DOMAINS, ["applinks:chiich.one"])]
            for target, key, value in invalid:
                def mutate(current, ent):
                    if current == target:
                        ent[key] = value
                with self.subTest(target=target, key=key, value=value), \
                     patch.object(signing, "run", side_effect=native_results(config, entitlement_mutation=mutate)), \
                     self.assertRaises(ValueError):
                    signing.verify_app(app, "1.0.0", "6", services=config)
            def missing_domain(target, profile):
                if target == "ElementX":
                    profile["Entitlements"].pop(signing.ASSOCIATED_DOMAINS)
            with patch.object(signing, "run", side_effect=native_results(config, profile_mutation=missing_domain)), \
                 self.assertRaisesRegex(ValueError, "required entitlement"):
                signing.verify_app(app, "1.0.0", "6", services=config)

    def test_links_archive_rejects_push_runtime_metadata_even_with_valid_signature(self):
        with tempfile.TemporaryDirectory() as temp:
            app = app_fixture(Path(temp), services())
            with patch.object(signing, "run", side_effect=native_results(links())), \
                 self.assertRaisesRegex(ValueError, "push-disabled trial policy"):
                signing.verify_app(app, "1.0.0", "6", services=links())

    def test_package_preserves_links_mode_and_cannot_cross_to_trial_or_push(self):
        config = links()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); export = root / "export"; export.mkdir()
            (export / "native.ipa").write_bytes(b"synthetic-package")
            output = root / "distribution"
            with patch.object(signing, "verify_ipa"), patch.object(signing, "verify_live_association") as association:
                signing.package(export, output, "1.0.0", "6", "a" * 40, services=config)
                receipt = json.loads((output / "provenance.json").read_text())
                self.assertEqual(receipt["push_notifications"], signing.TRIAL)
                self.assertEqual(receipt["nse_filtering"], "omitted-unused-entitlement")
                self.assertEqual(receipt["native_services"], config)
                signing.verify_package(output, "1.0.0", "6", "a" * 40, services=config)
                association.assert_called_once_with(config)
                for wrong in (None, services(), services(universal_links=True)):
                    with self.subTest(mode=wrong), self.assertRaisesRegex(ValueError, "reviewed CHIICH source"):
                        signing.verify_package(output, "1.0.0", "6", "a" * 40, services=wrong)


class AssociationGateTests(unittest.TestCase):
    def test_public_check_uses_one_fixed_credential_free_bounded_request(self):
        reply = response(content_type="application/json; charset=utf-8")
        opener = Mock(); opener.open.return_value = reply
        with patch.object(signing, "build_opener", return_value=opener):
            result = signing.verify_live_association(links())
        opener.open.assert_called_once()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, signing.ASSOCIATION_URL)
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertNotIn("Authorization", request.headers)
        self.assertNotIn("Cookie", request.headers)
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)
        reply.read.assert_called_once_with(signing.ASSOCIATION_MAX_BYTES + 1)
        self.assertEqual(result["sha256"], hashlib.sha256(reply.read.return_value).hexdigest())

    def test_wrong_status_redirect_target_and_mime_fail_closed(self):
        bad = [response(status=302), response(status=503), response(url="https://other.invalid/aasa"),
               response(content_type="binary/octet-stream"), response(content_type="text/html"),
               response(content_type=None)]
        for reply in bad:
            opener = Mock(); opener.open.return_value = reply
            with self.subTest(status=reply.getcode(), mime=reply.headers.get("Content-Type")), \
                 patch.object(signing, "build_opener", return_value=opener), self.assertRaises(ValueError):
                signing.verify_live_association(links())
        self.assertIsNone(signing.NoAssociationRedirects().redirect_request(None, None, 302, "", {}, "https://other.invalid"))
        opener = Mock(); opener.open.side_effect = HTTPError(signing.ASSOCIATION_URL, 302, "redirect", {}, None)
        with patch.object(signing, "build_opener", return_value=opener), self.assertRaisesRegex(ValueError, "directly"):
            signing.verify_live_association(links())
        opener.open.assert_called_once()

    def test_malformed_oversized_or_different_association_is_rejected(self):
        expected = json.loads(signing.ASSOCIATION_FIXTURE.read_text())
        wrong_app = copy.deepcopy(expected); wrong_app["applinks"]["details"][0]["appIDs"] = ["OTHERTEAM00.one.chiich.app"]
        wrong_routes = copy.deepcopy(expected); wrong_routes["applinks"]["details"][0]["components"] = [{"/": "/*"}]
        wrong_type = copy.deepcopy(expected); wrong_type["applinks"]["defaults"]["caseSensitive"] = 0
        bad = [b"", b"not-json", b'[]', b'{"applinks": {}, "applinks": {}}',
               b" " * (signing.ASSOCIATION_MAX_BYTES + 1),
               json.dumps(wrong_app).encode(), json.dumps(wrong_routes).encode(), json.dumps(wrong_type).encode()]
        for payload in bad:
            opener = Mock(); opener.open.return_value = response(payload)
            with self.subTest(size=len(payload)), patch.object(signing, "build_opener", return_value=opener), self.assertRaises(ValueError):
                signing.verify_live_association(links())

    def test_trial_and_push_without_links_make_no_association_request(self):
        with patch.object(signing, "build_opener") as opener:
            self.assertIsNone(signing.verify_live_association(None))
            self.assertIsNone(signing.verify_live_association(services()))
            opener.assert_not_called()

    def test_association_failure_stops_install_before_any_secret_or_native_access(self):
        with patch.object(signing, "verify_live_association", side_effect=ValueError("AASA not ready")), \
             patch.object(signing, "read_secret") as secret, patch.object(signing, "run") as native, \
             patch.object(signing, "state_path") as state:
            with self.assertRaisesRegex(ValueError, "AASA not ready"):
                signing.install(Path("synthetic-source"), "1.0.0", "6", services=links())
            secret.assert_not_called(); native.assert_not_called(); state.assert_not_called()

    def test_manual_check_and_workflow_require_live_association_before_credentials(self):
        with patch.object(sys, "argv", ["signing", "check-services", "--service-mode", "links-only"]), \
             patch.object(signing, "verify_live_association", return_value={"sha256": "synthetic"}) as association, \
             patch("sys.stdout", new_callable=io.StringIO):
            signing.main()
        association.assert_called_once_with(links())
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/chiich-ios-device.yml").read_text()
        self.assertIn("options: [disabled-trial, links-only, services-enabled]", workflow)
        self.assertIn("default: disabled-trial", workflow)
        self.assertLess(workflow.index("signing.py check-services"), workflow.index("environment: chiich-ios-signing"))


if __name__ == "__main__":
    unittest.main()
