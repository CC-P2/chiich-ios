// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation
import Observation

/// Shares the existing web account-data event. The SDK owns authentication, storage and /sync.
/// Its pinned custom-event observer is unavailable, so refresh reads only the SDK's local store.
@Observable
final class CHIICHReceiverAIPreferences {
    nonisolated struct Value: Codable, Equatable, Sendable {
        let enabled: Bool
        let language: String

        static func decode(_ json: String) throws -> Self {
            guard json.utf8.count <= 4096,
                  let data = json.data(using: .utf8),
                  let value = try? JSONDecoder().decode(Self.self, from: data),
                  CHIICHReceiverAILanguage.validTarget(value.language) else { throw CHIICHReceiverAIError.invalidResponse }
            return .init(enabled: value.enabled, language: CHIICHReceiverAILanguage.normalize(value.language))
        }

        func json() throws -> String {
            guard let result = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
                throw CHIICHReceiverAIError.invalidRequest
            }
            return result
        }
    }

    typealias Read = () async -> Result<String?, CHIICHReceiverAIError>
    typealias Write = (String) async -> Result<Void, CHIICHReceiverAIError>
    static let eventType = "one.chiich.receiver_ai"

    private(set) var value: Value
    private(set) var isReady: Bool
    private(set) var syncFailed = false
    var onChange: () -> Void = { }

    private let defaults: UserDefaults
    private let key: String
    private let read: Read?
    private let write: Write?
    private var dirtyEnabled: Bool
    private var dirtyLanguage: Bool
    private var syncGeneration = 0
    private var invalidated = false
    private var refreshRequested = false
    private var syncTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var awaitingEcho: Value?
    private var echoBase: Value?
    private var awaitingEchoSyncGeneration: Int?

    init(accountID: String, defaults: UserDefaults = .standard, read: Read? = nil, write: Write? = nil) {
        self.defaults = defaults
        self.read = read
        self.write = write
        key = "chiich.receiver-ai." + CHIICHReceiverAIIdentity.hash([accountID])
        let language = CHIICHReceiverAILanguage.normalize(defaults.string(forKey: key + ".language") ?? Locale.preferredLanguages.first ?? "en")
        value = .init(enabled: defaults.object(forKey: key + ".enabled") as? Bool ?? false,
                      language: CHIICHReceiverAILanguage.validTarget(language) ? language : "en")
        dirtyEnabled = defaults.bool(forKey: key + ".pendingEnabled")
        dirtyLanguage = defaults.bool(forKey: key + ".pendingLanguage")
        awaitingEcho = defaults.string(forKey: key + ".awaitingEcho").flatMap { try? Value.decode($0) }
        echoBase = defaults.string(forKey: key + ".echoBase").flatMap { try? Value.decode($0) }
        isReady = read == nil && write == nil
    }

    func setEnabled(_ enabled: Bool) {
        guard !invalidated, value.enabled != enabled else { return }
        dirtyEnabled = write != nil
        update(.init(enabled: enabled, language: value.language))
        persist()
        Task { [weak self] in await self?.refresh() }
    }

    func setLanguage(_ language: String) {
        let normalized = CHIICHReceiverAILanguage.normalize(language)
        guard !invalidated, CHIICHReceiverAILanguage.validTarget(normalized), value.language != normalized else { return }
        dirtyLanguage = write != nil
        update(.init(enabled: value.enabled, language: normalized))
        persist()
        Task { [weak self] in await self?.refresh() }
    }

    func refresh(accountDataSynced: Bool = false) async {
        guard !invalidated, read != nil, write != nil else { return }
        if accountDataSynced { syncGeneration += 1 }
        refreshRequested = true
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await drainRefreshes()
            syncTask = nil
        }
        syncTask = task
        await task.value
    }

    func startMonitoring() {
        guard !invalidated, read != nil, monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func invalidate() {
        invalidated = true
        stopMonitoring()
        syncTask?.cancel()
        refreshRequested = false
        isReady = false
    }

    private func drainRefreshes() async {
        while refreshRequested, !invalidated, !Task.isCancelled {
            refreshRequested = false
            do {
                try await synchronize()
                syncFailed = false
            } catch {
                // Keep the current local choice and pending settings; never clear Matrix storage.
                // A later native sync, foreground refresh or explicit retry can resume this unpaid write.
                if !invalidated { syncFailed = true }
                refreshRequested = false
            }
        }
    }

    private func synchronize() async throws {
        guard let read, let write, !invalidated else { return }
        let readSyncGeneration = syncGeneration
        let json = try await read().get()
        guard !invalidated, !Task.isCancelled else { return }
        let remote = try json.map(Value.decode)
        // A newly opened SDK store can be empty before its first /sync. Do not overwrite
        // the old web setting or start paid AI from a local default during that interval.
        guard remote != nil || readSyncGeneration > 0 else { return }
        // The first sync after a write may have started before that write. A second
        // confirmed sync can legitimately return the old value if another device
        // changed it back and the SDK coalesced our echo. A restored acknowledgement
        // predates this client's first sync, so one confirmed sync suffices.
        let canTrustEchoBase = awaitingEchoSyncGeneration.map { readSyncGeneration >= $0 + 2 } ?? (readSyncGeneration > 0)
        if let awaitingEcho, remote == echoBase, remote != awaitingEcho, !canTrustEchoBase {
            // SDK setAccountData is acknowledged before the corresponding /sync echo.
            // A stale local-store read must not undo the just-saved choice.
            if !dirtyEnabled && !dirtyLanguage {
                becomeReady()
                return
            }
        } else if awaitingEcho != nil {
            self.awaitingEcho = nil
            echoBase = nil
            awaitingEchoSyncGeneration = nil
            persist()
        }
        let baseline = awaitingEcho ?? remote ?? value
        update(.init(enabled: dirtyEnabled ? value.enabled : baseline.enabled,
                     language: dirtyLanguage ? value.language : baseline.language))
        becomeReady()
        guard dirtyEnabled || dirtyLanguage || remote == nil else { persist(); return }
        let snapshot = value
        try await write(snapshot.json()).get()
        guard !invalidated, !Task.isCancelled else { return }
        awaitingEcho = snapshot
        echoBase = remote
        awaitingEchoSyncGeneration = syncGeneration
        if value.enabled == snapshot.enabled { dirtyEnabled = false }
        if value.language == snapshot.language { dirtyLanguage = false }
        persist()
        refreshRequested = refreshRequested || dirtyEnabled || dirtyLanguage
    }

    private func update(_ next: Value) {
        guard next != value else { return }
        value = next
        onChange()
    }

    private func becomeReady() {
        guard !isReady else { return }
        isReady = true
        onChange()
    }

    private func persist() {
        defaults.set(value.enabled, forKey: key + ".enabled")
        defaults.set(value.language, forKey: key + ".language")
        defaults.set(dirtyEnabled, forKey: key + ".pendingEnabled")
        defaults.set(dirtyLanguage, forKey: key + ".pendingLanguage")
        defaults.set(try? awaitingEcho?.json(), forKey: key + ".awaitingEcho")
        defaults.set(try? echoBase?.json(), forKey: key + ".echoBase")
    }
}
