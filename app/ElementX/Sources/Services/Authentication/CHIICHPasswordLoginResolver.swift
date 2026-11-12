// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

nonisolated struct CHIICHPasswordLoginIdentifier: Equatable, Sendable {
    let username: String
    let expectedUserID: String?
}

/// Resolves an owned public alias before the existing SDK password exchange.
/// The public lookup never receives a password, token, cookie or account mutation.
final class CHIICHPasswordLoginResolver {
    typealias Request = (URLRequest) async -> Result<Data, CHIICHIdentityError>

    private let request: Request

    init(request: @escaping Request = { await CHIICHIdentityHTTP.send($0) }) {
        self.request = request
    }

    func resolve(username: String, homeserver: String) async throws -> CHIICHPasswordLoginIdentifier {
        try Task.checkCancellation()
        let native = CHIICHPasswordLoginIdentifier(username: username, expectedUserID: nil)
        // Full Matrix IDs, historical localparts and other servers retain the SDK path.
        guard let alias = try? CHIICHPublicUsername(chosen: username),
              let lookup = try? CHIICHIdentityRequest.resolve(alias).urlRequest(homeserver: homeserver) else {
            return native
        }
        let result = await request(lookup)
        try Task.checkCancellation()
        switch result {
        case .failure(.notFound):
            // Only an authoritative 404 allows a historical localpart password attempt.
            // This never provisions an account or claims a public alias.
            return native
        case .failure(let error):
            throw error
        case .success(let data):
            guard data.count <= CHIICHIdentityHTTP.responseLimit else { throw CHIICHIdentityError.invalidResponse }
            do {
                let recipient = try JSONDecoder().decode(CHIICHIdentityRecipient.self, from: data).validated()
                // A retired alias can return its owner's new name, but always the same owned MXID.
                return CHIICHPasswordLoginIdentifier(username: recipient.userID, expectedUserID: recipient.userID)
            } catch {
                throw CHIICHIdentityError.invalidResponse
            }
        }
    }
}
