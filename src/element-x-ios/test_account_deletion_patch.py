"""Delivery integrity only. Behavioral regressions are native CHIICHDeletionTests.

This does not claim that Swift tests, production deletion, or iPhone tests ran.
"""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


class AccountDeletionDeliveryTests(unittest.TestCase):
    def test_deletion_overlay_is_pinned_after_its_native_dependencies(self):
        lock = json.loads((ROOT / 'upstream.lock.json').read_text())
        paths = [entry['path'] for entry in lock['patches']]
        entry = lock['patches'][paths.index('patches/account-deletion.patch')]
        for dependency in ('patches/feature-parity.patch', 'patches/first-chat-consent.patch',
                           'patches/plaintext-onboarding.patch'):
            self.assertLess(paths.index(dependency), paths.index(entry['path']))
        self.assertEqual(hashlib.sha256((ROOT / entry['path']).read_bytes()).hexdigest(), entry['sha256'])

    def test_confirmed_cleanup_preserves_instance_identity_to_native_coordinator(self):
        patch = (ROOT / 'patches/account-deletion.patch').read_text()
        additions = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))
        self.assertIn('case didConfirmCHIICHAccountClosure(clientIdentity: ObjectIdentifier)', additions)
        self.assertIn('let clientIdentity = ObjectIdentifier(userSession.clientProxy)', additions)
        self.assertIn('ObjectIdentifier(activeClient) == clientIdentity else { return }', additions)
        self.assertIn('func confirmedClosurePreservesClientIdentityAcrossTheManager()', additions)
        self.assertNotIn('actionsSubject.send(.forceLogout)', additions)

    def test_native_regressions_and_all_localizations_are_delivered(self):
        patch = (ROOT / 'patches/account-deletion.patch').read_text()
        paths = [line[6:] for line in patch.splitlines() if line.startswith('+++ b/')]
        self.assertIn('UnitTests/Sources/CHIICHDeletionTests.swift', paths)
        for locale in ('en', 'ru', 'zh-Hans'):
            self.assertIn(f'ElementX/Resources/Localizations/{locale}.lproj/CHIICHDeletion.strings', paths)
        self.assertIn('ElementX/Sources/Mocks/ClientProxyMock.swift', paths)
        self.assertTrue(all(path.startswith(('ElementX/', 'UnitTests/')) for path in paths))


if __name__ == '__main__':
    unittest.main()
