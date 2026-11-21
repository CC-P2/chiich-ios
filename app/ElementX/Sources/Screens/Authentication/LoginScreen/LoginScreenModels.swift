//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

enum LoginScreenViewModelAction {
    /// The homeserver was updated to one that supports OAuth.
    case configuredForOAuth
    /// Login was successful.
    case signedIn(UserSessionProtocol)
    case continueWithSSO(SSOIdentityProvider, UIWindow)
    
    var isConfiguredForOAuth: Bool {
        switch self {
        case .configuredForOAuth: true
        default: false
        }
    }
}

nonisolated enum LoginScreenConfigurationState: Equatable, Sendable {
    case ready
    case loading
    case failed(message: String)
}

struct LoginScreenViewState: BindableState {
    /// Data about the selected homeserver.
    var homeserver: LoginHomeserver
    /// Whether a new homeserver is currently being loaded.
    var isLoading = false
    var configurationState: LoginScreenConfigurationState = .ready
    var window: UIWindow?
    /// Password fallback signs in an existing account; it never registers one.
    var allowsPasswordFallback = false
    var allowsCHIICHRegistration = false
    var didRegisterAccount = false
    var isPasswordLoginExpanded = false
    /// View state that can be bound to from SwiftUI.
    var bindings = LoginScreenBindings()
    
    /// The types of login supported by the homeserver.
    var loginMode: LoginMode {
        homeserver.loginMode
    }
    
    var canShowPasswordFallback: Bool {
        configurationState == .ready && loginMode == .sso && homeserver.supportsPasswordLogin && allowsPasswordFallback
    }
    
    var isPasswordLoginVisible: Bool {
        loginMode == .password || (canShowPasswordFallback && isPasswordLoginExpanded)
    }
    
    /// `true` if the username and password are ready to be submitted.
    var hasValidCredentials: Bool {
        !bindings.username.isEmpty && !bindings.password.isEmpty
    }
    
    /// `true` when valid credentials have been entered and a homeserver has been loaded.
    var canSubmit: Bool {
        configurationState == .ready && isPasswordLoginVisible && hasValidCredentials && !isLoading
    }
}

struct LoginScreenBindings {
    /// The username input by the user.
    var username = ""
    /// The password input by the user.
    var password = ""
    /// Information describing the currently displayed alert.
    var alertInfo: AlertInfo<LoginScreenErrorType>?
}

enum LoginScreenViewAction {
    /// Discover the fixed provider, or retry a failed discovery without leaving this screen.
    case configureAccountProvider
    case signInAfterRegistration
    case togglePasswordLogin
    case updateWindow(UIWindow?)
    case continueWithSSO(SSOIdentityProvider)
    /// Parse the username to detect if a homeserver is included.
    case parseUsername
    /// Continue using the input username and password.
    case next
}

enum LoginScreenErrorType: Hashable {
    /// An alert that informs the user to check their username/password.
    case credentialsAlert
    /// An alert that informs the user that their account has been deactivated.
    case deactivatedAlert
    /// An alert that allows the user to learn about sliding sync.
    case slidingSyncAlert
    /// An alert that informs the user that Element Pro should be used for a particular server.
    case elementProAlert
    /// An alert that informs the user that login failed due to a refresh token being returned.
    case refreshTokenAlert
    /// The response from the homeserver was unexpected.
    case unknown
}
