//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct LoginScreen: View {
    /// The focus state of the username text field.
    @FocusState private var isUsernameFocused: Bool
    /// The focus state of the password text field.
    @FocusState private var isPasswordFocused: Bool
    
    @State private var showingRegistration = false

    @Bindable var context: LoginScreenViewModel.Context
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CHIICHDeletionNoticeView()
                header
                    .padding(.top, 44)
                    .padding(.bottom, 40)
                
                switch context.viewState.configurationState {
                case .loading:
                    ProgressView(L10n.commonLoading)
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .accessibilityIdentifier("chiich.login.connecting")
                case .failed(let message):
                    VStack(spacing: 24) {
                        Text(message)
                            .font(.compound.bodyMD)
                            .foregroundColor(.compound.textSecondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.actionRetry) { context.send(viewAction: .configureAccountProvider) }
                            .buttonStyle(.compound(.secondary))
                            .disabled(context.viewState.isLoading)
                            .accessibilityIdentifier("chiich.login.retry")
                    }
                case .ready:
                    if context.viewState.didRegisterAccount {
                        Text(CHIICHRegistration.text("created"))
                            .font(.compound.bodyMD)
                            .padding(.bottom, 12)
                    }
                    authenticationOptions
                    if context.viewState.allowsCHIICHRegistration, context.viewState.homeserver.supportsPasswordLogin {
                        Button(CHIICHRegistration.text("create")) { showingRegistration = true }
                            .buttonStyle(.compound(.secondary))
                            .padding(.top, 16)
                            .disabled(context.viewState.isLoading)
                            .accessibilityIdentifier("chiich.login.registerWithPassword")
                    }
                }

                Link(L10n.commonPrivacyPolicy, destination: AppSettings.chiichPrivacyURL)
                    .font(.compound.bodySM)
                    .padding(.top, 20)
                    .accessibilityIdentifier("chiich.login.privacy")
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRegistration) {
            CHIICHRegistrationScreen { userID, password in
                context.username = userID
                context.password = password
                showingRegistration = false
                context.send(viewAction: .signInAfterRegistration)
            }
        }
        .alert(item: $context.alertInfo)
        .introspect(.window, on: .supportedVersions) { window in
            context.send(viewAction: .updateWindow(window))
        }
    }
    
    @ViewBuilder
    private var authenticationOptions: some View {
        switch context.viewState.loginMode {
        case .sso:
            VStack(spacing: 24) {
                SSOProviderButtons { context.send(viewAction: .continueWithSSO($0)) }
                    .disabled(context.viewState.isLoading || context.viewState.window == nil)
                Text(NSLocalizedString("chiich_sso_first_login", tableName: "CHIICHAuthentication", comment: "SSO registration explanation"))
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                if context.viewState.canShowPasswordFallback {
                    Button {
                        context.send(viewAction: .togglePasswordLogin)
                    } label: {
                        Text(NSLocalizedString(context.viewState.isPasswordLoginExpanded ? "chiich_hide_password_login" : "chiich_password_login",
                                               tableName: "CHIICHAuthentication",
                                               comment: "Existing-account password fallback"))
                    }
                    .buttonStyle(.compound(.secondary))
                    .disabled(context.viewState.isLoading)
                    .accessibilityIdentifier("chiich.login.passwordFallback")
                    if context.viewState.isPasswordLoginVisible {
                        loginForm
                            .disabled(context.viewState.isLoading)
                    }
                }
            }
        case .password:
            loginForm
                .disabled(context.viewState.isLoading)
        case .oAuth:
            // The unrestricted upstream flow returns to its OAuth coordinator.
            ProgressView()
        default:
            loginUnavailableText
        }
    }
    
    /// The header containing the title and icon.
    var header: some View {
        VStack(spacing: 8) {
            CHIICHBrandMark()
                .frame(width: 116, height: 116)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            
            Text("CHIICH")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.compound.textPrimary)
                .accessibilityAddTraits(.isHeader)
            
            Text(NSLocalizedString("chiich_login_tagline", tableName: "CHIICHAuthentication", comment: "CHIICH brand meaning"))
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
    }
    
    /// The form with text fields for username and password, along with a submit button.
    var loginForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(text: $context.username) {
                Text(L10n.commonUsername).foregroundColor(.compound.textSecondary)
            }
            .focused($isUsernameFocused)
            .textFieldStyle(.compound(labelText: L10n.screenLoginFormHeader, accessibilityIdentifier: A11yIdentifiers.loginScreen.emailUsername))
            .disableAutocorrection(true)
            .textContentType(.username)
            .autocapitalization(.none)
            .submitLabel(.next)
            .onChange(of: isUsernameFocused) { _, newValue in
                usernameFocusChanged(isFocussed: newValue)
            }
            .onSubmit { isPasswordFocused = true }
            .padding(.bottom, 20)
            
            SecureField(text: $context.password) {
                Text(L10n.commonPassword).foregroundColor(.compound.textSecondary)
            }
            .focused($isPasswordFocused)
            .textFieldStyle(.compound(accessibilityIdentifier: A11yIdentifiers.loginScreen.password))
            .textContentType(.password)
            .submitLabel(.done)
            .onSubmit(submit)
            
            Spacer().frame(height: 32)
            
            Button(action: submit) {
                Text(L10n.actionContinue)
            }
            .buttonStyle(.compound(.primary))
            .disabled(!context.viewState.canSubmit)
            .accessibilityIdentifier(A11yIdentifiers.loginScreen.continue)
        }
    }
    
    /// Text shown if neither password or OAuth login is supported.
    var loginUnavailableText: some View {
        Text(L10n.screenLoginErrorUnsupportedAuthentication)
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundColor(.compound.textPrimary)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(A11yIdentifiers.loginScreen.unsupportedServer)
    }
    
    /// Parses the username for a homeserver.
    private func usernameFocusChanged(isFocussed: Bool) {
        guard !isFocussed, !context.username.isEmpty else { return }
        context.send(viewAction: .parseUsername)
    }
    
    /// Sends the `next` view action so long as valid credentials have been input.
    private func submit() {
        guard context.viewState.canSubmit else { return }
        context.send(viewAction: .next)
        isUsernameFocused = false
        isPasswordFocused = false
    }
}

// MARK: - Previews

@available(iOS 26.0, *)
struct LoginScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let credentialsViewModel = makeViewModel(withCredentials: true)
    static let unconfiguredViewModel = makeViewModel(serverNameOrBaseURL: "somethingtofailconfiguration")
    
    static var previews: some View {
        ElementNavigationStack {
            LoginScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.homeserver.loginMode).map { $0 == .password })
        .previewDisplayName("Initial State")
        
        ElementNavigationStack {
            LoginScreen(context: credentialsViewModel.context)
        }
        .snapshotPreferences(expect: credentialsViewModel.context.observe(\.viewState.homeserver.loginMode).map { $0 == .password })
        .previewDisplayName("Credentials Entered")
        
        ElementNavigationStack {
            LoginScreen(context: unconfiguredViewModel.context)
        }
        .previewDisplayName("Unsupported")
    }
    
    static func makeViewModel(serverNameOrBaseURL: String = "example.com", withCredentials: Bool = false) -> LoginScreenViewModel {
        let authenticationService = AuthenticationService.mock
        
        Task { await authenticationService.configure(for: serverNameOrBaseURL, flow: .login) }
        
        let viewModel = LoginScreenViewModel(authenticationService: authenticationService,
                                             loginHint: nil,
                                             userIndicatorController: UserIndicatorControllerMock(),
                                             appSettings: .volatile())
        
        if withCredentials {
            viewModel.context.username = "alice"
            viewModel.context.password = "password"
        }
        
        return viewModel
    }
}

@available(iOS 26.0, *)
struct ChiichLogin_Previews: PreviewProvider, TestablePreview {
    static let socialViewModel = makeViewModel()
    static let fallbackViewModel = makeViewModel(passwordExpanded: true)
    static let connectingViewModel = makeViewModel(configurationState: .loading)
    static let failedViewModel = makeViewModel(configurationState: .failed(message: NSLocalizedString("chiich_login_connection_error",
                                                                                                      tableName: "CHIICHAuthentication",
                                                                                                      comment: "Owned homeserver discovery failed")))
    
    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        ElementNavigationStack {
            LoginScreen(context: socialViewModel.context)
        }
        .previewDisplayName("CHIICH Sign In")
        
        ElementNavigationStack {
            LoginScreen(context: fallbackViewModel.context)
        }
        .previewDisplayName("CHIICH Password Fallback")
        
        ElementNavigationStack {
            LoginScreen(context: connectingViewModel.context)
        }
        .previewDisplayName("CHIICH Connecting")
        
        ElementNavigationStack {
            LoginScreen(context: failedViewModel.context)
        }
        .previewDisplayName("CHIICH Connection Failed")
    }
    
    static func makeViewModel(configurationState: LoginScreenConfigurationState = .ready, passwordExpanded: Bool = false) -> LoginScreenViewModel {
        let viewModel = LoginScreenViewModel(authenticationService: AuthenticationService.mock,
                                             loginHint: nil,
                                             userIndicatorController: UserIndicatorControllerMock(),
                                             appSettings: .volatile())
        // Keep static preview states independent of the service's queued discovery update.
        viewModel.cancellables.removeAll()
        viewModel.state.homeserver.loginMode = .sso
        viewModel.state.homeserver.supportsPasswordLogin = true
        viewModel.state.configurationState = configurationState
        viewModel.state.allowsPasswordFallback = true
        viewModel.state.isPasswordLoginExpanded = passwordExpanded
        return viewModel
    }
}
