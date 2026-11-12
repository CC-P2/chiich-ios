// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// Shares the existing registry and Matrix session; aliases never create or merge accounts.
final class CHIICHIdentityService {
    typealias Request = (CHIICHIdentityRequest) async -> Result<Data, CHIICHIdentityError>

    private let request: Request
    private let sessionIsCurrent: () -> Bool

    var isSessionCurrent: Bool { sessionIsCurrent() }

    init(request: @escaping Request, isSessionCurrent: @escaping () -> Bool) {
        self.request = request
        sessionIsCurrent = isSessionCurrent
    }

    convenience init?(clientProxy: ClientProxyProtocol) {
        let accountID = clientProxy.userID
        let deviceID = clientProxy.deviceID
        let homeserver = clientProxy.homeserver
        guard CHIICHIdentityRecipient.isOwnedUserID(accountID),
              (try? CHIICHIdentityRequest.current.urlRequest(homeserver: homeserver)) != nil else { return nil }
        self.init(request: { [weak clientProxy] request in
            guard let clientProxy else { return .failure(.sessionChanged) }
            return await clientProxy.chiichIdentityRequest(request, accountID: accountID)
        }, isSessionCurrent: { [weak clientProxy] in
            guard let clientProxy else { return false }
            return clientProxy.chiichReceiverAIIsSessionActive && clientProxy.userID == accountID
                && clientProxy.deviceID == deviceID && clientProxy.homeserver == homeserver
        })
    }

    func current() async -> Result<CHIICHPublicUsername?, CHIICHIdentityError> {
        await username(for: .current)
    }

    func rename(to username: CHIICHPublicUsername) async -> Result<CHIICHPublicUsername, CHIICHIdentityError> {
        let result = await self.username(for: .rename(username))
        switch result {
        case .success(let confirmed):
            guard let confirmed, confirmed == username else { return .failure(.invalidResponse) }
            return .success(confirmed)
        case .failure(let error): return .failure(error)
        }
    }

    func resolve(_ username: CHIICHPublicUsername) async -> Result<CHIICHIdentityRecipient, CHIICHIdentityError> {
        guard isSessionCurrent, !Task.isCancelled else { return .failure(.sessionChanged) }
        let result = await request(.resolve(username))
        guard isSessionCurrent, !Task.isCancelled else { return .failure(.cancelled) }
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let data):
            do {
                // Retired aliases deliberately return the owner's current name and unchanged MXID.
                return try .success(JSONDecoder().decode(CHIICHIdentityRecipient.self, from: data).validated())
            } catch { return .failure(.invalidResponse) }
        }
    }

    private func username(for payload: CHIICHIdentityRequest) async -> Result<CHIICHPublicUsername?, CHIICHIdentityError> {
        guard isSessionCurrent, !Task.isCancelled else { return .failure(.sessionChanged) }
        let result = await request(payload)
        guard isSessionCurrent, !Task.isCancelled else { return .failure(.cancelled) }
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let data):
            do { return try .success(JSONDecoder().decode(CHIICHIdentityResponse.self, from: data).validated()) }
            catch { return .failure(.invalidResponse) }
        }
    }
}
