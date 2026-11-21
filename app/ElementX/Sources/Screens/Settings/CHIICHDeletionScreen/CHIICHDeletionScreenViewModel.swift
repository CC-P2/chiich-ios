// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Combine
import SwiftUI

typealias CHIICHDeletionScreenViewModelType = StateStoreViewModelV2<CHIICHDeletionScreenViewState, CHIICHDeletionScreenViewAction>

final class CHIICHDeletionScreenViewModel: CHIICHDeletionScreenViewModelType {
    private let service: CHIICHDeletionService?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var presentedBrowser: CHIICHPasswordSSOPresentation?
    private var isClosed = false

    private let dismissalSubject = PassthroughSubject<Void, Never>()
    var dismissalPublisher: AnyPublisher<Void, Never> { dismissalSubject.eraseToAnyPublisher() }

    init(service: CHIICHDeletionService?) {
        self.service = service
        super.init(initialViewState: .init())
    }

    func start() {
        guard let service else {
            state.mode = .unavailable
            state.error = .unsupportedServer
            return
        }
        if let pending = service.pendingSSO, service.browserReturned(nonce: pending.nonce) {
            state.mode = .authentication
            state.challenge = pending.challenge
            state.returnedBrowserNonce = pending.nonce
        }
    }

    func stop() {
        guard !isClosed else { return }
        isClosed = true
        operationID = UUID()
        // Do not cancel a submitted HTTP request when sync removes the initiating session.
        operationTask = nil
        if state.isWorking { service?.close() } else { service?.leaveScreen() }
        state.isWorking = false
        clearFields()
        state.bindings.browser = nil
        state.returnedBrowserNonce = nil
        state.challenge = nil
        presentedBrowser = nil
    }

    override func process(viewAction: CHIICHDeletionScreenViewAction) {
        // Actions and state must not be logged: the screen holds credentials while editing.
        guard !isClosed else { return }
        switch viewAction {
        case .close:
            service?.close()
            stop()
            dismissalSubject.send(())
        case .requestDeletion:
            guard state.mode == .entry, !state.isWorking else { return }
            state.bindings.confirmationShown = true
        case .confirmDeletion:
            guard let service, state.mode == .entry, !state.isWorking else { return }
            state.bindings.confirmationShown = false
            perform(kind: .initial) { await service.begin(confirmed: true) }
        case .submitPassword:
            submitCurrentPassword()
        case .openSSO:
            openSSO()
        case .browserReturned(let nonce):
            browserReturned(nonce)
        case .browserSheetDismissed:
            if let nonce = presentedBrowser?.id { browserReturned(nonce) }
        case .confirmSSO:
            // This is an explicit tap, including when Safari hasn't dismissed itself.
            if let nonce = presentedBrowser?.id { browserReturned(nonce) }
            guard let service, let nonce = state.returnedBrowserNonce else { return }
            perform(kind: .sso) { await service.confirmSSO(nonce: nonce) }
        case .finishCompletedChallenge:
            guard let service else { return }
            perform(kind: .complete) { await service.finishCompletedChallenge() }
        }
    }

    // MARK: - Private

    private enum SubmissionKind: Equatable { case initial, password, sso, complete }

    private func submitCurrentPassword() {
        guard let service, state.mode == .authentication, !state.isWorking else { return }
        let password = state.bindings.currentPassword
        guard !password.isEmpty else {
            state.error = .currentPasswordRequired
            return
        }
        state.bindings.currentPassword = ""
        perform(kind: .password) { await service.submitPassword(password) }
    }

    private func openSSO() {
        guard let service, !isClosed, !state.isWorking, presentedBrowser == nil else { return }
        clearFields()
        switch service.ssoPresentation() {
        case .success(let presentation):
            presentedBrowser = presentation
            state.returnedBrowserNonce = nil
            state.error = nil
            state.bindings.browser = presentation
        case .failure(let error):
            state.error = error
        }
    }

    private func browserReturned(_ nonce: UUID) {
        guard !isClosed, presentedBrowser?.id == nonce else { return }
        state.bindings.browser = nil
        presentedBrowser = nil
        guard service?.browserReturned(nonce: nonce) == true else {
            service?.close()
            state.mode = .unavailable
            state.challenge = nil
            state.error = .sessionChanged
            return
        }
        state.returnedBrowserNonce = nonce
    }

    private func perform(kind: SubmissionKind, operation: @escaping () async -> CHIICHDeletionService.Submission) {
        guard !isClosed, !state.isWorking else { return }
        state.isWorking = true
        state.error = nil
        let currentOperation = UUID()
        operationID = currentOperation
        operationTask = Task { [weak self] in
            let result = await operation()
            guard let self, !isClosed, operationID == currentOperation, !Task.isCancelled else { return }
            operationTask = nil
            state.isWorking = false
            state.returnedBrowserNonce = nil
            switch result {
            case .success(.success):
                clearFields()
                state.challenge = nil
                state.mode = .success
            case .success(.challenge(let challenge)):
                state.challenge = challenge
                state.mode = .authentication
                state.returnedBrowserNonce = service?.pendingSSO?.nonce
                if challenge.errcode != nil {
                    state.error = .authenticationRejected
                } else if kind == .sso {
                    state.error = .authenticationIncomplete
                }
            case .failure(let error):
                service?.close()
                clearFields()
                state.challenge = nil
                state.error = error
                // Terminal: the user must inspect the outcome before starting another deletion.
                state.mode = .unavailable
            }
        }
    }

    private func clearFields() {
        state.bindings.currentPassword = ""
    }
}
