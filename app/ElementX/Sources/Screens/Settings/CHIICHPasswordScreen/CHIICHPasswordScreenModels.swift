// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

enum CHIICHPasswordScreenMode: Equatable {
    case loading
    case entry
    case authentication
    case success
    case unavailable
}

struct CHIICHPasswordScreenViewState: BindableState {
    var mode: CHIICHPasswordScreenMode = .loading
    var isWorking = false
    var challenge: CHIICHPasswordChallenge?
    var returnedBrowserNonce: UUID?
    var error: CHIICHPasswordError?
    var bindings = CHIICHPasswordScreenBindings()

    var canSubmitNewPassword: Bool {
        !isWorking && !bindings.newPassword.isEmpty && !bindings.confirmation.isEmpty
    }
}

struct CHIICHPasswordScreenBindings {
    var newPassword = ""
    var confirmation = ""
    var currentPassword = ""
    var browser: CHIICHPasswordSSOPresentation?
}

enum CHIICHPasswordScreenViewAction {
    case save
    case submitPassword
    case openSSO
    case browserReturned(UUID)
    case browserSheetDismissed
    case confirmSSO
    case finishCompletedChallenge
    case close
}
