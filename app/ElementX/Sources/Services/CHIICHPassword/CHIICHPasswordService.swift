// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// An in-memory adapter for the server's standard UIA transaction, not a login/session implementation.
final class CHIICHPasswordService {
    typealias Submission = Result<CHIICHPasswordResponse, CHIICHPasswordError>

    let context: CHIICHPasswordContext
    private let sessionIsCurrent: () -> Bool
    private let capabilityRequest: () async -> CHIICHPasswordCapability
    private let submitRequest: (CHIICHPasswordRequest) async -> Submission

    private var capability: CHIICHPasswordCapability?
    private var operationID = UUID()
    private var pendingPassword: String?
    private var challenge: CHIICHPasswordChallenge?
    private var browserNonce: UUID?
    private var returnedBrowserNonce: UUID?
    private var isStarting = false
    private var isSubmitting = false
    private var isClosed = false

    init(context: CHIICHPasswordContext,
         sessionIsCurrent: @escaping () -> Bool,
         capabilityRequest: @escaping () async -> CHIICHPasswordCapability,
         submitRequest: @escaping (CHIICHPasswordRequest) async -> Submission) {
        self.context = context
        self.sessionIsCurrent = sessionIsCurrent
        self.capabilityRequest = capabilityRequest
        self.submitRequest = submitRequest
    }

    func prepare() async -> Result<CHIICHPasswordCapability, CHIICHPasswordError> {
        guard !isClosed, sessionIsCurrent(), !Task.isCancelled else { return .failure(.sessionChanged) }
        if let capability { return .success(capability) }
        let currentOperation = operationID
        let result = await capabilityRequest()
        guard !isClosed, operationID == currentOperation, sessionIsCurrent(), !Task.isCancelled else { return .failure(.sessionChanged) }
        capability = result
        return .success(result)
    }

    func begin(newPassword: String, confirmation: String) async -> Submission {
        guard !isClosed, !isStarting, !isSubmitting, pendingPassword == nil else { return .failure(.cancelled) }
        if let error = CHIICHPasswordRequest.validationError(newPassword: newPassword, confirmation: confirmation) { return .failure(error) }
        isStarting = true
        defer { isStarting = false }
        switch await prepare() {
        case .success(.disabled): return .failure(.serverDisabled)
        case .failure(let error): return .failure(error)
        case .success(.allowed), .success(.unknown): break
        }
        guard !isClosed, !isSubmitting, pendingPassword == nil else { return .failure(.cancelled) }
        operationID = UUID()
        pendingPassword = newPassword
        return await submit(authentication: nil)
    }

    func submitPassword(_ password: String) async -> Submission {
        guard let challenge, challenge.availableStages.contains(.password) else { return .failure(.expiredChallenge) }
        guard !password.isEmpty else { return .failure(.currentPasswordRequired) }
        guard password.unicodeScalars.count <= 512 else { return .failure(.passwordTooLong) }
        return await submit(authentication: .password(.init(identifier: context.accountID, password: password, session: challenge.session)))
    }

    func ssoPresentation() -> Result<CHIICHPasswordSSOPresentation, CHIICHPasswordError> {
        guard !isClosed, !isSubmitting, sessionIsCurrent(), pendingPassword != nil else { return .failure(.sessionChanged) }
        guard let challenge, challenge.availableStages.contains(.sso), let url = context.ssoURL(session: challenge.session) else {
            return .failure(.expiredChallenge)
        }
        let nonce = UUID()
        browserNonce = nonce
        returnedBrowserNonce = nil
        return .success(.init(id: nonce, url: url))
    }

    /// Closing the system browser says nothing about authentication. No POST is sent here.
    func browserReturned(nonce: UUID) -> Bool {
        guard !isClosed, sessionIsCurrent(), pendingPassword != nil, browserNonce == nonce else { return false }
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

    func cancel() {
        isClosed = true
        operationID = UUID()
        clearSecrets()
    }

    func discardPendingChange() {
        guard !isSubmitting else { return }
        operationID = UUID()
        clearSecrets()
    }

    // MARK: - Private

    private func submit(authentication: CHIICHPasswordAuth?) async -> Submission {
        guard !isClosed, !isSubmitting else { return .failure(.cancelled) }
        guard sessionIsCurrent(), !Task.isCancelled else {
            clearSecrets()
            return .failure(.sessionChanged)
        }
        guard let pendingPassword else { return .failure(.expiredChallenge) }
        if let authentication {
            guard let challenge, authentication.sessionID.utf8.elementsEqual(challenge.session.utf8) else { return .failure(.expiredChallenge) }
        }
        isSubmitting = true
        let currentOperation = operationID
        defer { if operationID == currentOperation { isSubmitting = false } }
        let result = await submitRequest(.init(newPassword: pendingPassword, authentication: authentication))
        guard !isClosed, currentOperation == operationID else { return .failure(.cancelled) }
        guard sessionIsCurrent(), !Task.isCancelled else {
            clearSecrets()
            return .failure(.sessionChanged)
        }
        switch result {
        case .success(.success):
            clearSecrets()
            isClosed = true
        case .success(.challenge(let updatedChallenge)):
            guard updatedChallenge.isValid, updatedChallenge.canContinue else {
                clearSecrets()
                return .failure(.unsupportedAuthentication)
            }
            if let challenge, !updatedChallenge.session.utf8.elementsEqual(challenge.session.utf8) {
                clearSecrets()
                return .failure(.expiredChallenge)
            }
            challenge = updatedChallenge
            browserNonce = nil
            returnedBrowserNonce = nil
        case .failure:
            // A rejected/uncertain submission is never replayed. A new attempt is an explicit user action.
            clearSecrets()
        }
        return result
    }

    private func clearSecrets() {
        pendingPassword = nil
        challenge = nil
        browserNonce = nil
        returnedBrowserNonce = nil
    }
}
