// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// A short-lived handoff within one SDK client, only when navigation removes the screen during SSO.
final class CHIICHDeletionRecovery {
    private var service: CHIICHDeletionService?
    private var deadline = ContinuousClock.now
    private var expiry: Task<Void, Never>?

    func save(_ pending: CHIICHDeletionService) {
        expiry?.cancel()
        service = pending
        deadline = ContinuousClock.now + .seconds(300)
        let deadline = self.deadline
        expiry = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, self.deadline == deadline else { return }
            self.service = nil
        }
    }

    func take() -> CHIICHDeletionService? {
        defer {
            expiry?.cancel()
            expiry = nil
            service = nil
        }
        guard ContinuousClock.now < deadline, service?.pendingSSO != nil else { return nil }
        return service
    }
}

/// Reuses standard UIA models. An attempt is single-use after any uncertain outcome.
final class CHIICHDeletionService {
    typealias Submission = Result<CHIICHPasswordResponse, CHIICHPasswordError>
    let context: CHIICHPasswordContext
    private weak var recovery: CHIICHDeletionRecovery?
    private let sessionIsCurrent: () -> Bool
    private let submitRequest: (CHIICHDeletionRequest) async -> Submission
    private let confirmedSuccess: () -> Void
    private var challenge: CHIICHPasswordChallenge?
    private var browserNonce: UUID?
    private var returnedBrowserNonce: UUID?
    private var started = false
    private var submitting = false
    private var closed = false

    init(context: CHIICHPasswordContext,
         recovery: CHIICHDeletionRecovery? = nil,
         sessionIsCurrent: @escaping () -> Bool,
         submitRequest: @escaping (CHIICHDeletionRequest) async -> Submission,
         confirmedSuccess: @escaping () -> Void = {}) {
        self.context = context
        self.recovery = recovery
        self.sessionIsCurrent = sessionIsCurrent
        self.submitRequest = submitRequest
        self.confirmedSuccess = confirmedSuccess
    }

    /// The view calls this only after the destructive confirmation.
    func begin(confirmed: Bool) async -> Submission {
        guard confirmed, !started, !closed else { return .failure(.cancelled) }
        started = true
        return await submit(authentication: nil)
    }

    func submitPassword(_ password: String) async -> Submission {
        guard let challenge, challenge.availableStages.contains(.password) else { return .failure(.expiredChallenge) }
        guard !password.isEmpty else { return .failure(.currentPasswordRequired) }
        guard password.unicodeScalars.count <= 512 else { return .failure(.passwordTooLong) }
        return await submit(authentication: .password(.init(identifier: context.accountID, password: password, session: challenge.session)))
    }

    func ssoPresentation() -> Result<CHIICHPasswordSSOPresentation, CHIICHPasswordError> {
        guard !closed, !submitting, sessionIsCurrent(), started else { return .failure(.sessionChanged) }
        guard let challenge, challenge.availableStages.contains(.sso), let url = context.ssoURL(session: challenge.session) else {
            return .failure(.expiredChallenge)
        }
        let nonce = UUID()
        browserNonce = nonce
        returnedBrowserNonce = nil
        return .success(.init(id: nonce, url: url))
    }

    var pendingSSO: (challenge: CHIICHPasswordChallenge, nonce: UUID)? {
        guard !closed, !submitting, sessionIsCurrent(), let challenge, let browserNonce,
              challenge.availableStages.contains(.sso) else { return nil }
        return (challenge, browserNonce)
    }

    func leaveScreen() {
        guard let recovery, pendingSSO != nil else { close(); return }
        recovery.save(self)
    }

    /// Browser dismissal never authenticates or sends the destructive request.
    func browserReturned(nonce: UUID) -> Bool {
        guard !closed, !submitting, sessionIsCurrent(), browserNonce == nonce else { return false }
        returnedBrowserNonce = nonce
        return true
    }

    func confirmSSO(nonce: UUID) async -> Submission {
        guard let challenge, challenge.availableStages.contains(.sso),
              browserNonce == nonce, returnedBrowserNonce == nonce else { return .failure(.expiredChallenge) }
        returnedBrowserNonce = nil
        return await submit(authentication: .session(challenge.session))
    }

    func finishCompletedChallenge() async -> Submission {
        guard let challenge, challenge.isComplete else { return .failure(.expiredChallenge) }
        return await submit(authentication: .session(challenge.session))
    }

    /// Keep observing a submitted request even when sync tears down this screen.
    /// Closing the UI cancels future stages, not the already-authorized server operation.
    func close() {
        closed = true
        clearChallenge()
    }

    private func submit(authentication: CHIICHPasswordAuth?) async -> Submission {
        guard !closed, !submitting, started else { return .failure(.cancelled) }
        guard sessionIsCurrent(), !Task.isCancelled else { close(); return .failure(.sessionChanged) }
        if let authentication {
            guard let challenge, authentication.sessionID.utf8.elementsEqual(challenge.session.utf8) else { return .failure(.expiredChallenge) }
        }
        submitting = true
        defer { submitting = false }
        let result = await submitRequest(.init(authentication: authentication))
        // Deactivation revokes the initiating token. The successful response is authoritative
        // even if sync already removed that session, or a different account is now active.
        if result == .success(.success) {
            close()
            confirmedSuccess()
            return result
        }
        guard !closed, !Task.isCancelled else { close(); return .failure(.outcomeUnknown) }
        guard sessionIsCurrent() else { close(); return .failure(.outcomeUnknown) }
        switch result {
        case .success(.challenge(let updated)):
            guard updated.isValid, updated.canContinue else { close(); return .failure(.unsupportedAuthentication) }
            if let challenge, !updated.session.utf8.elementsEqual(challenge.session.utf8) {
                close(); return .failure(.expiredChallenge)
            }
            challenge = updated
            if case .session? = authentication, updated.availableStages.contains(.sso) {
                // The provider may still be finishing. Recheck the same session on an explicit tap.
                returnedBrowserNonce = browserNonce
            } else {
                browserNonce = nil
                returnedBrowserNonce = nil
            }
        case .failure(let error):
            close()
            return .failure(error == .cancelled ? .outcomeUnknown : error)
        case .success(.success): break // Handled before session revalidation.
        }
        return result
    }

    private func clearChallenge() {
        challenge = nil
        browserNonce = nil
        returnedBrowserNonce = nil
    }
}
