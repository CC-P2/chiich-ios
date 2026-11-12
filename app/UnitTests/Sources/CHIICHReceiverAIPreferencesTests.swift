// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

final class CHIICHReceiverAIPreferencesTests {
    @Test
    func oldWebAccountPreferenceWinsOverLegacyNativeDefault() async throws {
        let fixture = try Fixture()
        fixture.defaults.set(true, forKey: fixture.key + ".enabled")
        fixture.defaults.set("en", forKey: fixture.key + ".language")
        fixture.remote = #"{"enabled":false,"language":"de"}"#
        let preferences = fixture.makePreferences()
        #expect(!preferences.isReady)
        await preferences.refresh()
        #expect(preferences.isReady)
        #expect(!preferences.value.enabled)
        #expect(preferences.value.language == "de")
        #expect(fixture.writes.isEmpty)
    }

    @Test
    func emptySDKStoreBeforeFirstSyncCannotOverwriteOldWebSettings() async throws {
        let fixture = try Fixture()
        let preferences = fixture.makePreferences()
        await preferences.refresh()
        #expect(!preferences.isReady)
        #expect(fixture.writes.isEmpty)
        fixture.remote = #"{"enabled":false,"language":"uk"}"#
        await preferences.refresh(accountDataSynced: true)
        #expect(preferences.isReady)
        #expect(!preferences.value.enabled)
        #expect(preferences.value.language == "uk")
        #expect(fixture.writes.isEmpty)
    }

    @Test
    func missingAccountEventMigratesAnExistingLocalChoiceAfterSync() async throws {
        let fixture = try Fixture()
        fixture.defaults.set(false, forKey: fixture.key + ".enabled")
        fixture.defaults.set("es", forKey: fixture.key + ".language")
        let preferences = fixture.makePreferences()
        await preferences.refresh(accountDataSynced: true)
        #expect(fixture.writes == [.init(enabled: false, language: "es")])
        #expect(preferences.isReady)
        await preferences.refresh()
        #expect(fixture.writes.count == 1)
    }

    @Test
    func pendingOfflineFieldMergesWithOtherDeviceSettingsAfterRestart() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":false,"language":"ru"}"#
        let first = fixture.makePreferences()
        await first.refresh()
        fixture.failWrites = true
        first.setLanguage("ja")
        await first.refresh()
        #expect(first.syncFailed)
        first.invalidate()
        fixture.failWrites = false
        fixture.remote = #"{"enabled":true,"language":"ru"}"#
        let restored = fixture.makePreferences()
        await restored.refresh()
        #expect(restored.value == .init(enabled: true, language: "ja"))
        #expect(fixture.writes.last == restored.value)
    }

    @Test
    func delayedSDKSyncEchoCannotUndoAcknowledgedSettings() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":true,"language":"en"}"#
        fixture.autoEcho = false
        let preferences = fixture.makePreferences()
        await preferences.refresh()
        preferences.setLanguage("fr")
        await preferences.refresh()
        #expect(preferences.value.language == "fr")
        await preferences.refresh()
        #expect(preferences.value.language == "fr")
        #expect(fixture.writes.count == 1)
        fixture.remote = #"{"enabled":true,"language":"fr"}"#
        await preferences.refresh(accountDataSynced: true)
        fixture.remote = #"{"enabled":false,"language":"en"}"#
        await preferences.refresh(accountDataSynced: true)
        #expect(preferences.value == .init(enabled: false, language: "en"))
    }

    @Test
    func coalescedEchoDoesNotPermanentlyHideAnotherDeviceRevertingTheSetting() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":true,"language":"en"}"#
        fixture.autoEcho = false
        let preferences = fixture.makePreferences()
        await preferences.refresh()
        preferences.setLanguage("fr")
        await preferences.refresh()
        await preferences.refresh(accountDataSynced: true)
        #expect(preferences.value.language == "fr")
        await preferences.refresh(accountDataSynced: true)
        #expect(preferences.value.language == "en")
        #expect(fixture.writes.count == 1)
    }

    @Test
    func restoredAcknowledgementDefersToFirstConfirmedSyncButNotStartupCache() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":true,"language":"en"}"#
        fixture.autoEcho = false
        let first = fixture.makePreferences()
        await first.refresh()
        first.setLanguage("fr")
        await first.refresh()
        first.invalidate()
        let restored = fixture.makePreferences()
        await restored.refresh()
        #expect(restored.value.language == "fr")
        await restored.refresh(accountDataSynced: true)
        #expect(restored.value.language == "en")
        #expect(fixture.writes.count == 1)
    }

    @Test
    func confirmedSyncCannotUndoAnUnsentExplicitDisabledChoice() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":true,"language":"en"}"#
        fixture.autoEcho = false
        let preferences = fixture.makePreferences()
        await preferences.refresh()
        preferences.setLanguage("fr")
        await preferences.refresh()
        fixture.failWrites = true
        preferences.setEnabled(false)
        await preferences.refresh(accountDataSynced: true)
        await preferences.refresh(accountDataSynced: true)
        #expect(!preferences.value.enabled)
        #expect(preferences.value.language == "en")
        #expect(preferences.syncFailed)
        #expect(fixture.defaults.bool(forKey: fixture.key + ".pendingEnabled"))
        fixture.failWrites = false
        await preferences.refresh()
        #expect(fixture.writes.last == .init(enabled: false, language: "en"))
    }

    @Test
    func rapidChangesAreSerializedAndNewestChoiceIsEventuallySaved() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":true,"language":"en"}"#
        let preferences = fixture.makePreferences()
        await preferences.refresh()
        fixture.holdWrite = true
        preferences.setLanguage("de")
        try await Self.waitUntil { fixture.writeContinuation != nil }
        preferences.setLanguage("es")
        preferences.setEnabled(false)
        fixture.releaseWrite()
        await preferences.refresh()
        #expect(fixture.maximumConcurrentWrites == 1)
        #expect(fixture.writes.last == .init(enabled: false, language: "es"))
        #expect(preferences.value == .init(enabled: false, language: "es"))
    }

    @Test
    func invalidAccountDataIsNotReplacedWithLocalDefaults() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":"yes","language":"ru"}"#
        let preferences = fixture.makePreferences()
        await preferences.refresh(accountDataSynced: true)
        #expect(!preferences.isReady)
        #expect(preferences.syncFailed)
        #expect(fixture.writes.isEmpty)
    }

    @Test
    func logoutRejectsLatePreferenceReadAndStopsWrites() async throws {
        let fixture = try Fixture()
        fixture.remote = #"{"enabled":false,"language":"ja"}"#
        fixture.holdRead = true
        let preferences = fixture.makePreferences()
        let refresh = Task { await preferences.refresh(accountDataSynced: true) }
        try await Self.waitUntil { fixture.readContinuation != nil }
        preferences.invalidate()
        fixture.readContinuation?.resume()
        fixture.readContinuation = nil
        await refresh.value
        #expect(!preferences.isReady)
        #expect(fixture.writes.isEmpty)
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate())
    }

    private final class Fixture {
        let suite = UUID().uuidString
        let defaults: UserDefaults
        let account = "@reader:chat.chiich.one"
        var key: String { "chiich.receiver-ai." + CHIICHReceiverAIIdentity.hash([account]) }
        var remote: String?
        var writes: [CHIICHReceiverAIPreferences.Value] = []
        var failWrites = false
        var autoEcho = true
        var holdRead = false
        var holdWrite = false
        var readContinuation: CheckedContinuation<Void, Never>?
        var writeContinuation: CheckedContinuation<Void, Never>?
        var concurrentWrites = 0
        var maximumConcurrentWrites = 0

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        isolated deinit {
            defaults.removePersistentDomain(forName: suite)
        }

        func makePreferences() -> CHIICHReceiverAIPreferences {
            .init(accountID: account, defaults: defaults,
                  read: { [weak self] in
                      guard let self else { return .failure(.cancelled) }
                      if holdRead { await withCheckedContinuation { readContinuation = $0 } }
                      return .success(remote)
                  },
                  write: { [weak self] json in
                      guard let self else { return .failure(.cancelled) }
                      concurrentWrites += 1
                      maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
                      defer { concurrentWrites -= 1 }
                      if holdWrite { await withCheckedContinuation { writeContinuation = $0 } }
                      if failWrites { return .failure(.unavailable) }
                      guard let value = try? CHIICHReceiverAIPreferences.Value.decode(json) else { return .failure(.invalidRequest) }
                      writes.append(value)
                      if autoEcho { remote = json }
                      return .success(())
                  })
        }

        func releaseWrite() {
            holdWrite = false
            writeContinuation?.resume()
            writeContinuation = nil
        }
    }
}
