// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Combine
import SwiftUI

typealias CHIICHPasswordScreenViewModelType = StateStoreViewModelV2<CHIICHPasswordScreenViewState, CHIICHPasswordScreenViewAction>

final class CHIICHPasswordScreenViewModel: CHIICHPasswordScreenViewModelType {
    private let service: CHIICHPasswordService?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var presentedBrowser: CHIICHPasswordSSOPresentation?
    private var isClosed = false

    private let dismissalSubject = PassthroughSubject<Void, Never>()
    var dismissalPublisher: AnyPublisher<Void, Never> { dismissalSubject.eraseToAnyPublisher() }

    init(service: CHIICHPasswordService?) {
        self.service = service
        super.init(initialViewState: .init())
    }

    func start() {
        guard !isClosed, operationTask == nil else { return }
        guard let service else {
            state.mode = .unavailable
            state.error = .unsupportedServer
            return
        }
        operationTask = Task { [weak self] in
            let result = await service.prepare()
            guard let self, !isClosed, !Task.isCancelled else { return }
            operationTask = nil
            switch result {
            case .success(.disabled):
                state.mode = .unavailable
                state.error = .serverDisabled
            case .success(.allowed), .success(.unknown):
                state.mode = .entry
            case .failure(let error):
                state.mode = .unavailable
                state.error = error
            }
        }
    }

    func stop() {
        isClosed = true
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        service?.cancel()
        state.isWorking = false
        clearFields()
        state.bindings.browser = nil
        state.returnedBrowserNonce = nil
        state.challenge = nil
        presentedBrowser = nil
    }

    override func process(viewAction: CHIICHPasswordScreenViewAction) {
        // Actions and state must not be logged: the screen holds credentials while editing.
        switch viewAction {
        case .close:
            stop()
            dismissalSubject.send(())
        case .save:
            save()
        case .submitPassword:
            submitCurrentPassword()
        case .openSSO:
            openSSO()
        case .browserReturned(let nonce):
            browserReturned(nonce)
        case .browserSheetDismissed:
            if let nonce = presentedBrowser?.id { browserReturned(nonce) }
        case .confirmSSO:
            guard let service, let nonce = state.returnedBrowserNonce else { return }
            perform(kind: .sso) { await service.confirmSSO(nonce: nonce) }
        case .finishCompletedChallenge:
            guard let service else { return }
            perform(kind: .complete) { await service.finishCompletedChallenge() }
        }
    }

    // MARK: - Private

    private enum SubmissionKind: Equatable { case initial, password, sso, complete }

    private func save() {
        guard let service, state.mode == .entry, !state.isWorking else { return }
        let newPassword = state.bindings.newPassword
        let confirmation = state.bindings.confirmation
        if let error = CHIICHPasswordRequest.validationError(newPassword: newPassword, confirmation: confirmation) {
            state.error = error
            return
        }
        clearFields()
        perform(kind: .initial) { await service.begin(newPassword: newPassword, confirmation: confirmation) }
    }

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
            service?.cancel()
            state.mode = .unavailable
            state.challenge = nil
            state.error = .sessionChanged
            return
        }
        state.returnedBrowserNonce = nonce
    }

    private func perform(kind: SubmissionKind, operation: @escaping () async -> CHIICHPasswordService.Submission) {
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
                if challenge.errcode != nil {
                    state.error = .authenticationRejected
                } else if kind == .sso {
                    state.error = .authenticationIncomplete
                }
            case .failure(let error):
                service?.discardPendingChange()
                clearFields()
                state.challenge = nil
                state.error = error
                switch error {
                case .sessionChanged, .matrixUnknownToken, .cancelled, .serverDisabled, .unsupportedServer:
                    state.mode = .unavailable
                default:
                    state.mode = .entry
                }
            }
        }
    }

    private func clearFields() {
        state.bindings.newPassword = ""
        state.bindings.confirmation = ""
        state.bindings.currentPassword = ""
    }
}
