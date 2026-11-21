// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

nonisolated enum CHIICHDeletionStrings {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "CHIICHDeletion", comment: "CHIICH account deletion")
    }
    static func message(for error: CHIICHPasswordError) -> String {
        switch error {
        case .outcomeUnknown, .cancelled: text("unknown_outcome")
        case .sessionChanged, .matrixUnknownToken: text("session_changed")
        case .unsupportedServer, .serverDisabled: text("unavailable")
        case .expiredChallenge: text("expired")
        case .rateLimited: text("rate_limit")
        case .invalidResponse: text("invalid_response")
        default: CHIICHPasswordStrings.message(for: error)
        }
    }
}

/// A non-identifying receipt survives SDK logout; never persist user IDs, tokens, passwords or UIA sessions.
enum CHIICHDeletionNotice {
    static let key = "confirmedAccountClosure"
    static let defaults = UserDefaults(suiteName: "one.chiich.app.deletion-notice") ?? .standard
    static func recordConfirmedResponse() { defaults.set(true, forKey: key) }
}
