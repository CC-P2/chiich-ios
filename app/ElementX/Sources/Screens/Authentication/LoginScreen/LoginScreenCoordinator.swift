//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct LoginScreenCoordinatorParameters {
    /// The service used to authenticate the user.
    let authenticationService: AuthenticationServiceProtocol
    /// An optional hint that can be used to pre-fill the form.
    let loginHint: String?
    let userIndicatorController: UserIndicatorControllerProtocol
    let appSettings: AppSettings
    /// Configure the owned provider on this screen instead of showing a welcome step.
    var initialAccountProvider: AccountProvider?
}

enum LoginScreenCoordinatorAction {
    /// The homeserver was updated to one that supports OAuth.
    case configuredForOAuth
    /// Login was successful.
    case signedIn(UserSessionProtocol)
}

/// Note: This code was brought over from Riot, we should move the authentication service logic into the view model.
final class LoginScreenCoordinator: CoordinatorProtocol {
    private var viewModel: LoginScreenViewModelProtocol
    private let parameters: LoginScreenCoordinatorParameters
    private var ssoPresenter: SSOAuthenticationPresenter?
    private var ssoTask: Task<Void, Never>?
    
    private let actionsSubject: PassthroughSubject<LoginScreenCoordinatorAction, Never> = .init()
    private var cancellables = Set<AnyCancellable>()
    
    var actions: AnyPublisher<LoginScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Setup
    
    init(parameters: LoginScreenCoordinatorParameters) {
        self.parameters = parameters
        viewModel = LoginScreenViewModel(authenticationService: parameters.authenticationService,
                                         loginHint: parameters.loginHint,
                                         userIndicatorController: parameters.userIndicatorController,
                                         appSettings: parameters.appSettings,
                                         initialAccountProvider: parameters.initialAccountProvider)
    }
    
    // MARK: - Public
    
    func start() {
        cancellables.removeAll()
        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .continueWithSSO(let provider, let window):
                    continueWithSSO(provider, window: window)
                case .configuredForOAuth:
                    actionsSubject.send(.configuredForOAuth)
                case .signedIn(let userSession):
                    actionsSubject.send(.signedIn(userSession))
                }
            }
            .store(in: &cancellables)
        
        viewModel.context.send(viewAction: .configureAccountProvider)
    }
    
    func stop() {
        viewModel.cancelInitialConfiguration()
        if ssoPresenter?.cancel() != false {
            ssoTask?.cancel()
        }
        viewModel.stopLoading()
    }
    
    private func continueWithSSO(_ provider: SSOIdentityProvider, window: UIWindow) {
        guard ssoTask == nil, let service = parameters.authenticationService as? SSOAuthenticationServiceProtocol else {
            viewModel.stopLoading()
            return
        }
        let presenter = SSOAuthenticationPresenter(service: service, anchor: window, indicators: parameters.userIndicatorController)
        ssoPresenter = presenter
        ssoTask = Task { [weak self] in
            guard let self else { return }
            let result = await presenter.authenticate(provider: provider)
            ssoPresenter = nil
            ssoTask = nil
            viewModel.stopLoading()
            switch result {
            case .success(let userSession): actionsSubject.send(.signedIn(userSession))
            case .failure(.ssoError(.cancelled)): break
            case .failure: viewModel.context.alertInfo = AlertInfo(id: .unknown)
            }
        }
    }
    
    func toPresentable() -> AnyView {
        AnyView(LoginScreen(context: viewModel.context))
    }
}
