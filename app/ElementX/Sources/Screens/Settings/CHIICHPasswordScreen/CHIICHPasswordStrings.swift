// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

nonisolated enum CHIICHPasswordStrings {
    static var title: String { text("title") }

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "CHIICHPassword", comment: "CHIICH account password")
    }

    static func message(for error: CHIICHPasswordError) -> String {
        let key: String = switch error {
        case .invalidPassword: "error_empty"
        case .passwordsDoNotMatch: "error_mismatch"
        case .passwordTooLong: "error_too_long"
        case .passwordPolicy: "error_policy"
        case .currentPasswordRequired: "error_current_required"
        case .authenticationRejected: "error_rejected"
        case .authenticationIncomplete: "error_incomplete"
        case .unsupportedAuthentication: "error_unsupported_auth"
        case .unsupportedServer: "error_unsupported_server"
        case .serverDisabled: "error_disabled"
        case .sessionChanged, .matrixUnknownToken: "error_session"
        case .expiredChallenge: "error_expired"
        case .rateLimited: "error_rate_limit"
        case .invalidResponse: "error_invalid_response"
        case .outcomeUnknown: "error_unknown_outcome"
        case .cancelled: "error_cancelled"
        }
        return text(key)
    }
}
