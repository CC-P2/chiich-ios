// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

// Match the released CHIICH strings' native locale fallback, including Russian and Chinese.
nonisolated extension L10n {
    static var screenChiichIdentityUsername: String { tr("Untranslated", "screen_chiich_identity_username") }
    static var screenChiichIdentityChooseUsername: String { tr("Untranslated", "screen_chiich_identity_choose_username") }
    static var screenChiichIdentityMyLink: String { tr("Untranslated", "screen_chiich_identity_my_link") }
    static var screenChiichIdentityInviteFriend: String { tr("Untranslated", "screen_chiich_identity_invite_friend") }
    static var screenChiichIdentityUsernameHint: String { tr("Untranslated", "screen_chiich_identity_username_hint") }
    static var screenChiichIdentityRefresh: String { tr("Untranslated", "screen_chiich_identity_refresh") }
    static var screenChiichIdentityOpening: String { tr("Untranslated", "screen_chiich_identity_opening") }
    static var screenChiichIdentityInvalidUsername: String { tr("Untranslated", "screen_chiich_identity_invalid_username") }
    static var screenChiichIdentityConflict: String { tr("Untranslated", "screen_chiich_identity_conflict") }
    static var screenChiichIdentityAliasLimit: String { tr("Untranslated", "screen_chiich_identity_alias_limit") }
    static var screenChiichIdentityRateLimited: String { tr("Untranslated", "screen_chiich_identity_rate_limited") }
    static var screenChiichIdentityNotFound: String { tr("Untranslated", "screen_chiich_identity_not_found") }
    static var screenChiichIdentityUnavailable: String { tr("Untranslated", "screen_chiich_identity_unavailable") }
    static var screenChiichIdentitySessionChanged: String { tr("Untranslated", "screen_chiich_identity_session_changed") }
    static var screenChiichIdentityUncertain: String { tr("Untranslated", "screen_chiich_identity_uncertain") }
}

nonisolated enum CHIICHIdentityStrings {
    static func message(for error: CHIICHIdentityError) -> String {
        switch error {
        case .invalidUsername: L10n.screenChiichIdentityInvalidUsername
        case .conflict: L10n.screenChiichIdentityConflict
        case .aliasLimit: L10n.screenChiichIdentityAliasLimit
        case .rateLimited: L10n.screenChiichIdentityRateLimited
        case .notFound: L10n.screenChiichIdentityNotFound
        case .sessionChanged, .matrixUnknownToken: L10n.screenChiichIdentitySessionChanged
        case .uncertain: L10n.screenChiichIdentityUncertain
        case .unavailable, .invalidResponse, .cancelled: L10n.screenChiichIdentityUnavailable
        }
    }
}
