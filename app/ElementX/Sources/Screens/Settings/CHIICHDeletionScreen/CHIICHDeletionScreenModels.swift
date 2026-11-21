// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

enum CHIICHDeletionScreenMode: Equatable { case entry, authentication, success, unavailable }
struct CHIICHDeletionScreenViewState: BindableState {
    var mode: CHIICHDeletionScreenMode = .entry
    var isWorking = false
    var challenge: CHIICHPasswordChallenge?
    var returnedBrowserNonce: UUID?
    var error: CHIICHPasswordError?
    var bindings = CHIICHDeletionScreenBindings()
}
struct CHIICHDeletionScreenBindings {
    var currentPassword = ""
    var confirmationShown = false
    var browser: CHIICHPasswordSSOPresentation?
}
enum CHIICHDeletionScreenViewAction {
    case requestDeletion, confirmDeletion, submitPassword, openSSO
    case browserReturned(UUID)
    case browserSheetDismissed, confirmSSO, finishCompletedChallenge, close
}
