"""Source guards only; simulator/device acceptance is separate."""
from pathlib import Path
import hashlib
import json
import re
import unittest

ROOT = Path(__file__).resolve().parent

class FirstChatConsentTests(unittest.TestCase):
    def setUp(self):
        self.patch = (ROOT / 'patches/first-chat-consent.patch').read_text()

    def test_manifest_and_overlay_order(self):
        lock = json.loads((ROOT / 'upstream.lock.json').read_text())
        paths = [item['path'] for item in lock['patches']]
        consent_index = paths.index('patches/first-chat-consent.patch')
        self.assertEqual(paths[consent_index - 1], 'patches/privacy-consent.patch')
        for item in lock['patches']:
            self.assertEqual(hashlib.sha256((ROOT / item['path']).read_bytes()).hexdigest(), item['sha256'])

    def test_automatic_prompt_requires_unmade_choice_and_active_session(self):
        for token in ('consent.decision == .undecided', '!consent.syncFailed',
                      '!Task.isCancelled', '!didPresentAutomaticConsent', 'sessionIsCurrent()',
                      'await service.prepareAutomaticConsentPrompt()'):
            self.assertIn(token, self.patch)
        self.assertIn('firstChatOffersConsentOnceWithoutProcessingOrChoosing', self.patch)
        self.assertIn('refusedFirstChatStaysOffAfterRestart', self.patch)
        self.assertIn('rememberedChoiceDoesNotPromptAgain', self.patch)
        self.assertIn('failedConsentReadDoesNotPromptOrAuthorize', self.patch)

    def test_details_stay_inside_app_and_keep_existing_disclosure(self):
        self.assertIn('.sheet(isPresented: $showingDetails)', self.patch)
        for key in ('screenChiichAiConsentTransfer', 'screenChiichAiConsentPeer', 'screenChiichAiConsentControl'):
            self.assertIn('+                Text(L10n.' + key + ')', self.patch)
        self.assertNotIn('https://', self.patch)
        self.assertIn('presentationBackground(.clear)', self.patch)
        self.assertIn('screen_chiich_ai_consent_summary', self.patch)
        self.assertIn('внешнему обработчику ИИ', self.patch)
        # Actual choices still use the original consent service; this overlay never grants on appear.
        self.assertNotIn('+            service.setConsent(true)', self.patch)

    def test_each_short_consent_translation_names_the_ai_processors(self):
        summaries = re.findall(r'^\+"screen_chiich_ai_consent_summary" = "(.*)";$',
                               self.patch, re.MULTILINE)
        self.assertEqual(len(summaries), 3)  # Existing English, Russian and Chinese translations.
        for summary in summaries:
            self.assertIn('ProxyAPI', summary)
            self.assertIn('OpenAI', summary)

if __name__ == '__main__':
    unittest.main()
