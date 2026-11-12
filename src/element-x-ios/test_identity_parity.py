"""Offline delivery checks for the owned identity-link association fixture.

These model Apple's documented wildcard/first-match rules, not an iOS device.
Native URL parsing, session guards and navigation are exercised by Swift tests.
"""
import json
import re
import unittest
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent
FIXTURE = ROOT / "fixtures" / "chiich-apple-app-site-association.json"


def wildcard(pattern, value, case_sensitive):
    expression = "".join(".*" if char == "*" else "." if char == "?" else re.escape(char) for char in pattern)
    return re.fullmatch(expression, value, 0 if case_sensitive else re.IGNORECASE) is not None


def association_matches(url):
    source = json.loads(FIXTURE.read_text())
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.hostname != "chiich.one":
        return False
    defaults = source["applinks"]["defaults"]
    for component in source["applinks"]["details"][0]["components"]:
        values = {"/": parts.path, "?": parts.query, "#": parts.fragment}
        if not component.get("percentEncoded", defaults.get("percentEncoded", True)):
            values = {name: unquote(value) for name, value in values.items()}
        sensitive = component.get("caseSensitive", defaults.get("caseSensitive", True))
        if all(wildcard(component[name], value, sensitive) for name, value in values.items() if name in component):
            return not component.get("exclude", False)
    return False


class IdentityAssociationTests(unittest.TestCase):
    def test_only_the_existing_app_identifier_is_associated(self):
        data = json.loads(FIXTURE.read_text())
        self.assertEqual(set(data), {"applinks"})
        self.assertEqual(data["applinks"]["details"][0]["appIDs"], ["RM8GR3A69Q.one.chiich.app"])
        self.assertLess(FIXTURE.stat().st_size, 128_000)

    def test_canonical_latin_and_cyrillic_public_links_match(self):
        for name in ("ivan2026", "IVAN2026", "иван2026", "%D0%B8%D0%B2%D0%B0%D0%BD2026", "123", "a" * 24):
            with self.subTest(name=name):
                self.assertTrue(association_matches("https://chiich.one/" + name))

    def test_web_pages_assets_callbacks_and_parameters_stay_in_browser(self):
        paths = ("/", "/ab", "/" + "a" * 25, "/element.html", "/config.json", "/manifest.webmanifest",
                 "/.well-known/apple-app-site-association", "/bundles/a.js", "/chiich-assets/a.png",
                 "/chiich-assets", "/user_name", "/login", "/LOGIN", "/profile", "/sso/callback",
                 "/ivan/extra", "/ivan/", "/ivan%2Fextra", "/ivan?token=synthetic", "/ivan#part")
        for path in paths:
            with self.subTest(path=path):
                self.assertFalse(association_matches("https://chiich.one" + path))

    def test_every_server_reserved_name_stays_in_browser(self):
        contract = json.loads((ROOT / "fixtures" / "chiich-public-username-contract.json").read_text())
        self.assertIn("98e5c53c77300efe8bf4a7bbc44e712134a9b563", contract["source"])
        self.assertEqual((contract["minimumLength"], contract["maximumLength"]), (3, 24))
        for reserved in contract["reserved"]:
            with self.subTest(reserved=reserved):
                self.assertFalse(association_matches("https://chiich.one/" + reserved))
                self.assertFalse(association_matches("https://chiich.one/" + reserved.upper()))


if __name__ == "__main__":
    unittest.main()
