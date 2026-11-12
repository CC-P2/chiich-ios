"""Source guards for deferring native verification under the existing plaintext policy.

These are not native Swift execution or physical-iPhone acceptance.
"""
from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parent


class PlaintextOnboardingTests(unittest.TestCase):
    def setUp(self):
        self.patch = (ROOT / 'patches/plaintext-onboarding.patch').read_text()

    def test_manifest_pins_overlay_after_existing_release(self):
        lock = json.loads((ROOT / 'upstream.lock.json').read_text())
        self.assertEqual(lock['patches'][-1]['path'], 'patches/plaintext-onboarding.patch')
        self.assertEqual(lock['patches'][-2]['path'], 'patches/first-chat-consent.patch')
        self.assertEqual(hashlib.sha256(self.patch.encode()).hexdigest(), lock['patches'][-1]['sha256'])

    def test_only_onboarding_presentation_and_its_tests_change(self):
        paths = [line.removeprefix('+++ b/') for line in self.patch.splitlines() if line.startswith('+++ b/')]
        self.assertEqual(paths, ['ElementX/Sources/FlowCoordinators/OnboardingFlowCoordinator.swift',
                                 'UnitTests/Sources/CHIICHOnboardingTests.swift',
                                 'ElementX/Sources/Screens/HomeScreen/HomeScreenViewModel.swift',
                                 'UnitTests/Sources/HomeScreenViewModelTests.swift',
                                 'ElementX/Sources/FlowCoordinators/UserSessionFlowCoordinator.swift',
                                 'UnitTests/Sources/CHIICHIdentityRoutingTests.swift'])
        coordinator = self.patch.split('diff --git a/UnitTests/')[0]
        additions = '\n'.join(line[1:] for line in coordinator.splitlines() if line.startswith('+') and not line.startswith('+++'))
        code = [line.strip() for line in additions.splitlines() if line.strip() and not line.strip().startswith('//')]
        self.assertEqual(code, ['guard !userSettings.app.forceDisableE2EE.publisher.value else { return false }'])
        for forbidden in ('resetIdentity(', '.verified)', 'hasRunIdentityConfirmationOnboarding = true',
                          'logout(', 'applyRemoteValue(', 'http://', 'https://'):
            self.assertNotIn(forbidden, additions)

    def test_native_regressions_cover_unverified_restored_and_encrypted_sessions(self):
        for test in ('plaintextNewLoginDoesNotPresentVerificationOrChangeSecurityState',
                     'plaintextRestoredSessionDoesNotShowBlockingVerification',
                     'enablingEncryptionRestoresNativeVerificationGate',
                     'plaintextPolicyDoesNotSkipPendingNotificationPermission',
                     'plaintextPolicyDoesNotSkipPendingAnalyticsConsent'):
            self.assertIn('func ' + test, self.patch)
        self.assertIn('SessionVerificationState.unknown, .unverified', self.patch)
        self.assertIn('verificationState == verificationState', self.patch)
        self.assertIn('!fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding', self.patch)

    def test_home_recovery_prompts_follow_existing_policy_without_mutating_recovery(self):
        self.assertIn('.combineLatest(userSettings.app.forceDisableE2EE.publisher)', self.patch)
        self.assertIn('guard !forceDisableE2EE else {', self.patch)
        self.assertIn('plaintextPolicySuppressesRecoveryPromptsWithoutChangingRecovery', self.patch)
        self.assertIn('recoveryPromptFollowsPolicyChangesWithoutChangingSecurityState', self.patch)
        self.assertNotIn('+                    secureBackupController.', self.patch)

    def test_unsolicited_verification_and_invitation_routing_honour_same_policy(self):
        self.assertIn('incomingVerificationPresentationFollowsPlaintextPolicy', self.patch)
        self.assertIn('plaintextInvitationDoesNotWaitForCryptographicVerification', self.patch)
        self.assertIn('+                guard !userSession.userSettings.app.forceDisableE2EE.publisher.value else { return }', self.patch)
        self.assertIn('|| userSession.sessionSecurityStatePublisher.value.verificationState != .unknown)', self.patch)


if __name__ == '__main__':
    unittest.main()
