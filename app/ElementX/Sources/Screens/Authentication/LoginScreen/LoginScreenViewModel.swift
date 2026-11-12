//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias LoginScreenViewModelType = StateStoreViewModelV2<LoginScreenViewState, LoginScreenViewAction>

class LoginScreenViewModel: LoginScreenViewModelType, LoginScreenViewModelProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let appSettings: AppSettings
    private let initialAccountProvider: AccountProvider?
    private var configurationTask: Task<Void, Never>?
    private var restartConfigurationAfterCancellation = false
    
    private var actionsSubject: PassthroughSubject<LoginScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<LoginScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(authenticationService: AuthenticationServiceProtocol,
         loginHint: String?,
         userIndicatorController: UserIndicatorControllerProtocol,
         appSettings: AppSettings,
         initialAccountProvider: AccountProvider? = nil) {
        self.authenticationService = authenticationService
        self.userIndicatorController = userIndicatorController
        self.appSettings = appSettings
        self.initialAccountProvider = initialAccountProvider
        
        let username = switch loginHint {
        case .some(let hint) where hint.hasPrefix("mxid:"): String(hint.dropFirst(5)) // MSC4198
        case .some(let hint): hint
        case .none: ""
        }
        
        let viewState = LoginScreenViewState(homeserver: authenticationService.homeserver.value,
                                             configurationState: initialAccountProvider == nil ? .ready : .loading,
                                             allowsPasswordFallback: authenticationService.flow == .login,
                                             bindings: LoginScreenBindings(username: username))
        
        super.init(initialViewState: viewState)
        
        authenticationService.homeserver
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.homeserver, on: self)
            .store(in: &cancellables)
    }
    
    override func process(viewAction: LoginScreenViewAction) {
        switch viewAction {
        case .configureAccountProvider:
            configureAccountProvider()
        case .togglePasswordLogin:
            guard !state.isLoading, state.canShowPasswordFallback else { return }
            state.isPasswordLoginExpanded.toggle()
            if !state.isPasswordLoginExpanded {
                state.bindings.password = ""
            }
        case .updateWindow(let window):
            guard state.window != window else { return }
            Task { state.window = window }
        case .continueWithSSO(let provider):
            guard state.configurationState == .ready, state.loginMode == .sso,
                  !state.isLoading, let window = state.window else { return }
            state.isLoading = true
            actionsSubject.send(.continueWithSSO(provider, window))
        case .parseUsername:
            parseUsername()
        case .next:
            guard state.canSubmit else { return }
            login()
        }
    }
    
    func stopLoading() {
        state.isLoading = false
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
    
    func cancelInitialConfiguration() {
        restartConfigurationAfterCancellation = false
        configurationTask?.cancel()
    }
    
    // MARK: - Private
    
    private func configureAccountProvider() {
        guard let initialAccountProvider, state.configurationState != .ready else { return }
        if let configurationTask {
            if configurationTask.isCancelled {
                restartConfigurationAfterCancellation = true
            }
            return
        }
        guard !state.isLoading else { return }
        
        state.configurationState = .loading
        state.isLoading = true
        configurationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                configurationTask = nil
                if Task.isCancelled {
                    state.configurationState = .failed(message: Self.connectionErrorMessage)
                    stopLoading()
                    if restartConfigurationAfterCancellation {
                        restartConfigurationAfterCancellation = false
                        configureAccountProvider()
                    }
                }
            }
            guard !Task.isCancelled else { return }
            
            let result = await authenticationService.configure(for: initialAccountProvider.serverNameOrBaseURL, flow: .login)
            guard !Task.isCancelled else { return }
            
            stopLoading()
            switch result {
            case .success:
                // Discovery only prepares the native service. Opening Apple or Google
                // always requires an explicit tap after the presentation window exists.
                state.homeserver = authenticationService.homeserver.value
                state.allowsPasswordFallback = authenticationService.flow == .login
                switch state.loginMode {
                case .sso, .password:
                    state.configurationState = .ready
                default:
                    state.configurationState = .failed(message: L10n.screenLoginErrorUnsupportedAuthentication)
                }
            case .failure:
                state.configurationState = .failed(message: Self.connectionErrorMessage)
            }
        }
    }
    
    private static var connectionErrorMessage: String {
        NSLocalizedString("chiich_login_connection_error", tableName: "CHIICHAuthentication", comment: "Owned homeserver discovery failed")
    }
    
    /// Parses the specified username and looks up the homeserver when a Matrix ID is entered.
    private func parseUsername() {
        // A full Matrix ID must never move CHIICH's fixed account provider.
        guard appSettings.allowOtherAccountProviders, !state.isLoading else { return }
        let username = state.bindings.username
        
        guard let homeserverDomain = try? serverNameFromUserId(userId: username) else { return }
        
        startLoading(isInteractionBlocking: false)
        
        Task {
            switch await authenticationService.configure(for: homeserverDomain, flow: .login) {
            case .success:
                if authenticationService.homeserver.value.loginMode.supportsOAuthFlow {
                    actionsSubject.send(.configuredForOAuth)
                }
                stopLoading()
            case .failure(let error):
                stopLoading()
                handleError(error)
            }
        }
    }
    
    /// Requests the authentication coordinator to log in using the specified credentials.
    private func login() {
        if !appSettings.allowOtherAccountProviders,
           let serverName = try? serverNameFromUserId(userId: state.bindings.username),
           !appSettings.accountProviders.contains(serverName: serverName, orBaseURL: nil) {
            handleError(.invalidCredentials)
            return
        }
        MXLog.info("Starting login with password.")
        startLoading(isInteractionBlocking: true)
        
        Task {
            switch await authenticationService.login(username: state.bindings.username,
                                                     password: state.bindings.password,
                                                     initialDeviceName: UIDevice.current.initialDeviceName,
                                                     deviceID: nil) {
            case .success(let userSession):
                actionsSubject.send(.signedIn(userSession))
                stopLoading()
            case .failure(let error):
                stopLoading()
                handleError(error)
            }
        }
    }
    
    private static let loadingIndicatorIdentifier = "\(LoginScreenCoordinatorAction.self)-Loading"
    
    private func startLoading(isInteractionBlocking: Bool) {
        state.isLoading = true
        if isInteractionBlocking {
            userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                                  type: .modal,
                                                                  title: L10n.commonLoading,
                                                                  persistent: true))
        }
    }
    
    /// Processes an error to either update the flow or display it to the user.
    private func handleError(_ error: AuthenticationServiceError) {
        MXLog.info("Error occurred: \(error)")
        
        switch error {
        case .invalidCredentials:
            state.bindings.alertInfo = AlertInfo(id: .credentialsAlert,
                                                 title: L10n.commonError,
                                                 message: L10n.screenLoginErrorInvalidCredentials)
        case .accountDeactivated:
            state.bindings.alertInfo = AlertInfo(id: .deactivatedAlert,
                                                 title: L10n.commonError,
                                                 message: L10n.screenLoginErrorDeactivatedAccount)
        case .invalidWellKnown(let error):
            state.bindings.alertInfo = AlertInfo(id: .slidingSyncAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenChangeServerErrorInvalidWellKnown(error))
        case .slidingSyncNotAvailable:
            let nonBreakingAppName = InfoPlistReader.main.bundleDisplayName.replacingOccurrences(of: " ", with: "\u{00A0}")
            state.bindings.alertInfo = AlertInfo(id: .slidingSyncAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenChangeServerErrorNoSlidingSyncMessage(nonBreakingAppName))
            
            // Clear out the invalid username to avoid an attempted login to matrix.org
            state.bindings.username = ""
        case .elementProRequired(let serverName):
            state.bindings.alertInfo = AlertInfo(id: .elementProAlert,
                                                 title: L10n.screenChangeServerErrorElementProRequiredTitle,
                                                 message: L10n.screenChangeServerErrorElementProRequiredMessage(serverName),
                                                 primaryButton: .init(title: L10n.screenChangeServerErrorElementProRequiredActionIos) {
                                                     UIApplication.shared.open(self.appSettings.elementProAppStoreURL)
                                                 },
                                                 secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
            // Clear out the invalid username to avoid an attempted login to matrix.org
            state.bindings.username = ""
        case .sessionTokenRefreshNotSupported:
            state.bindings.alertInfo = AlertInfo(id: .refreshTokenAlert,
                                                 title: L10n.commonServerNotSupported,
                                                 message: L10n.screenLoginErrorRefreshTokens)
        default:
            state.bindings.alertInfo = AlertInfo(id: .unknown)
        }
    }
}
