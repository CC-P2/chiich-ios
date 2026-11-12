//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The existing Synapse identity providers; these are server IDs, not client OAuth credentials.
nonisolated enum SSOIdentityProvider: String, CaseIterable {
    case apple = "oidc-apple"
    case google = "oidc-google"
}

nonisolated enum SSOError: Error, Equatable {
    case cancelled
    case unavailable
    case invalidCallback
    case failed
}

/// Additive legacy SSO support. OAuth/MAS remains a separate upstream authentication path.
protocol SSOAuthenticationServiceProtocol: AnyObject {
    func beginSSOLogin(provider: SSOIdentityProvider, callback: SSOCallback) async -> Result<SSOLoginRequest, AuthenticationServiceError>
    func finishSSOLogin(requestID: UUID, callbackURL: URL, expectedUserID: String?) async -> Result<UserSessionProtocol, AuthenticationServiceError>
    /// Returns false after native session persistence has begun; consume its successful result.
    @discardableResult func cancelSSOLogin(requestID: UUID) -> Bool
}

nonisolated struct SSOLoginRequest {
    let id: UUID
    let authorizationURL: URL
    let callback: SSOCallback
}

/// Synapse appends loginToken to the redirect. The SDK exchanges it but does not bind
/// the redirect to this attempt, so check the full destination before handing it back.
/// The token itself is never read, logged, persisted or exchanged by app code.
nonisolated struct SSOCallback {
    let id: UUID
    let url: URL

    init?(scheme: String, nonce: UUID = UUID()) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "sso"
        components.path = "/" + nonce.uuidString.lowercased()
        guard let url = components.url, url.scheme == scheme, !scheme.isEmpty else { return nil }
        id = nonce
        self.url = url
    }

    func accepts(_ candidate: URL) -> Bool {
        guard let received = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return received.scheme == expected.scheme && received.host == expected.host
            && received.percentEncodedPath == expected.percentEncodedPath
            && received.user == nil && received.password == nil && received.port == nil
            && received.fragment == nil
    }
}
