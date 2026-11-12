// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation
import Observation

/// A separate, versioned account-data event. Neither the old enabled flag nor a cached
/// cross-device preference authorizes a disclosure. An offline withdrawal survives restart.
@Observable
final class CHIICHReceiverAIConsent {
    enum Decision { case undecided, declined, granted }
    nonisolated struct Record: Codable, Equatable, Sendable {
        static let currentVersion = 1
        let version: Int
        let enabled: Bool

        init(enabled: Bool) {
            version = Self.currentVersion
            self.enabled = enabled
        }
    }

    nonisolated static let eventType = "one.chiich.receiver_ai.consent"

    private(set) var decision: Decision = .undecided
    private(set) var authorized = false
    private(set) var syncFailed = false
    var onChange: () -> Void = { }

    private let accountID: String
    private let defaults: UserDefaults
    private let withdrawalKey: String
    private let request: CHIICHReceiverAIService.Request
    private var pending: Bool?
    private var generation = 0
    private var invalidated = false
    private var work: Task<Void, Never>?
    private var rerun = false
    private var lastCheck: ContinuousClock.Instant?

    init(accountID: String, defaults: UserDefaults, request: @escaping CHIICHReceiverAIService.Request) {
        self.accountID = accountID
        self.defaults = defaults
        self.request = request
        withdrawalKey = "chiich.receiver-ai.consent.v1." + CHIICHReceiverAIIdentity.hash([accountID]) + ".withdraw"
        if defaults.bool(forKey: withdrawalKey) {
            pending = false
            decision = .declined
        }
    }

    func select(_ granted: Bool) {
        guard !invalidated else { return }
        generation += 1
        pending = granted
        // Even an interrupted or ambiguous grant must be corrected on restart.
        // Clear this marker only when the server acknowledges the current choice.
        defaults.set(true, forKey: withdrawalKey)
        decision = granted ? .granted : .declined
        authorized = false
        syncFailed = false
        onChange()
        Task { [weak self] in await self?.refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard !invalidated else { return }
        if let work {
            if force { rerun = true }
            await work.value
            return
        }
        if !force, let lastCheck, lastCheck.duration(to: .now) < .seconds(20) { return }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                rerun = false
                lastCheck = .now
                await synchronize()
            } while rerun && !invalidated && !Task.isCancelled
            work = nil
        }
        work = task
        await task.value
    }

    func invalidate() {
        invalidated = true
        generation += 1
        authorized = false
        work?.cancel()
    }

    private func synchronize() async {
        let rev = generation
        let choice = pending
        let command: CHIICHReceiverAIRequest = if let choice { .writeConsent(accountID, choice) } else { .readConsent(accountID) }
        let response = await request(command, nil)
        guard !invalidated, !Task.isCancelled else { return }
        guard generation == rev else { rerun = true; return }
        let previouslyAuthorized = authorized
        let previousDecision = decision
        switch response {
        case .success(let data):
            if let choice {
                pending = nil
                defaults.removeObject(forKey: withdrawalKey)
                decision = choice ? .granted : .declined
            } else if let record = try? JSONDecoder().decode(Record.self, from: data), record.version == Record.currentVersion {
                decision = record.enabled ? .granted : .declined
            } else {
                // Malformed or unknown-version consent never falls back to a previous grant.
                decision = .undecided
            }
            authorized = decision == .granted
            syncFailed = false
        case .failure(.accountDataMissing) where choice == nil:
            decision = .undecided
            authorized = false
            syncFailed = false
        case .failure:
            authorized = false
            syncFailed = true
            if choice == true {
                // A failed PUT may have reached the server. Retract it, never replay a grant
                // silently after connectivity returns. The user can explicitly choose again.
                pending = false
                decision = .declined
            }
        }
        if previousDecision != decision || previouslyAuthorized != authorized { onChange() }
    }
}
