"""Offline guards for the private iOS login session and system-visible name.

These check shipped source configuration, not iOS alert behavior. Device acceptance
must still cover both providers, cancellation, retry and an existing app session.
"""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


class LoginPresentationTests(unittest.TestCase):
    def test_sso_uses_private_session_before_start(self):
        source = (ROOT / 'patches/authentication.patch').read_text()
        start = source.index('+++ b/ElementX/Sources/Screens/Authentication/SSOAuthenticationPresenter.swift')
        presenter = source[start:source.index('\ndiff --git ', start)]
        setting = 'session.prefersEphemeralWebBrowserSession = true'
        self.assertEqual(presenter.count(setting), 1)
        self.assertLess(presenter.index(setting), presenter.index('session.start()'))
        self.assertNotIn('prefersEphemeralWebBrowserSession = false', presenter)
        self.assertIn('request.callback.accepts(url)', presenter)
        self.assertIn('session.cancel()', presenter)

    def test_system_name_uses_existing_brand_without_renaming_target(self):
        source = (ROOT / 'patches/configuration.patch').read_text()
        self.assertIn('+  APP_DISPLAY_NAME: CHIICH', source)
        self.assertIn('+        CFBundleName: $(APP_DISPLAY_NAME)', source)
        self.assertIn(' CFBundleDisplayName: $(APP_DISPLAY_NAME)', source)
        self.assertNotIn('+        PRODUCT_NAME:', source)

    def test_patch_manifest_matches_files(self):
        lock = json.loads((ROOT / 'upstream.lock.json').read_text())
        for item in lock['patches']:
            with self.subTest(path=item['path']):
                self.assertEqual(hashlib.sha256((ROOT / item['path']).read_bytes()).hexdigest(), item['sha256'])


if __name__ == '__main__':
    unittest.main()
