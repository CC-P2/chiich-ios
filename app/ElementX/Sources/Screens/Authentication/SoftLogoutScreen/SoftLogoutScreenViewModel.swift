//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SoftLogoutScreenViewModelType = StateStoreViewModelV2<SoftLogoutScreenViewState, SoftLogoutScreenViewAction>

class SoftLogoutScreenViewModel: SoftLogoutScreenViewModelType, SoftLogoutScreenViewModelProtocol {
    private var actionsSubject: PassthroughSubject<SoftLogoutScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<SoftLogoutScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(credentials: SoftLogoutScreenCredentials,
         homeserver: LoginHomeserver,
         keyBackupNeeded: Bool,
         password: String = "") {
        let bindings = SoftLogoutScreenBindings(password: password)
        let viewState = SoftLogoutScreenViewState(credentials: credentials,
                                                  homeserver: homeserver,
                                                  keyBackupNeeded: keyBackupNeeded,
                                                  bindings: bindings)
        super.init(initialViewState: viewState)
    }
    
    override func process(viewAction: SoftLogoutScreenViewAction) {
        switch viewAction {
        case .togglePasswordLogin:
            guard state.canShowPasswordFallback, !state.bindings.isAuthenticating else { return }
            state.isPasswordLoginExpanded.toggle()
            if !state.isPasswordLoginExpanded { state.bindings.password = "" }
        case .login:
            guard state.canSubmit else { return }
            state.bindings.isAuthenticating = true
            actionsSubject.send(.login(state.bindings.password))
        case .forgotPassword:
            guard !state.bindings.isAuthenticating else { return }
            actionsSubject.send(.forgotPassword)
        case .clearAllData:
            guard !state.bindings.isAuthenticating else { return }
            actionsSubject.send(.clearAllData)
        case .continueWithOAuth:
            actionsSubject.send(.continueWithOAuth)
        case .continueWithSSO(let provider):
            guard state.loginMode == .sso, !state.bindings.isAuthenticating, state.window != nil else { return }
            state.bindings.isAuthenticating = true
            actionsSubject.send(.continueWithSSO(provider))
        case .updateWindow(let window):
            guard state.window != window else { return }
            Task { state.window = window }
        }
    }
    
    func displayError(_ type: SoftLogoutScreenErrorType) {
        switch type {
        case .alert(let message):
            state.bindings.alertInfo = AlertInfo(id: type,
                                                 title: L10n.commonError,
                                                 message: message)
        case .refreshTokenAlert:
            state.bindings.alertInfo = AlertInfo(id: type,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenLoginErrorRefreshTokens)
        case .unknown:
            state.bindings.alertInfo = AlertInfo(id: type)
        }
    }
}
