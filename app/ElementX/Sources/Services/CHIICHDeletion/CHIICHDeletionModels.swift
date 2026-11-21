// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// A single account operation; no caller-selectable URL, erase flag, or account identity.
nonisolated struct CHIICHDeletionRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let authentication: CHIICHPasswordAuth?
    var description: String { "CHIICHDeletionRequest(<redacted>)" }
    var debugDescription: String { description }

    func urlRequest(context: CHIICHPasswordContext) throws -> URLRequest {
        var body: [String: Any] = ["erase": true]
        if let authentication {
            guard CHIICHPasswordChallenge.isValidSession(authentication.sessionID) else { throw CHIICHPasswordError.expiredChallenge }
            switch authentication {
            case .password(let details):
                guard details.identifier.utf8.elementsEqual(context.accountID.utf8), !details.password.isEmpty else { throw CHIICHPasswordError.currentPasswordRequired }
                guard details.password.unicodeScalars.count <= 512 else { throw CHIICHPasswordError.passwordTooLong }
                body["auth"] = ["type": "m.login.password",
                                "identifier": ["type": "m.id.user", "user": context.accountID],
                                "password": details.password, "session": details.session]
            case .session(let session): body["auth"] = ["session": session]
            }
        }
        var request = URLRequest(url: context.origin.appending(path: "_matrix/client/v3/account/deactivate"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum CHIICHDeletionResponse {
    static func classify(data: Data, statusCode: Int) -> Result<CHIICHPasswordResponse, CHIICHPasswordError> {
        guard statusCode == 200 else { return CHIICHPasswordHTTP.classify(data: data, statusCode: statusCode) }
        guard data.count <= CHIICHPasswordHTTP.maximumResponseBytes,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = body["id_server_unbind_result"] as? String,
              ["success", "no-support"].contains(result), body["errcode"] == nil, body["flows"] == nil else {
            return .failure(.outcomeUnknown)
        }
        return .success(.success)
    }
}

extension ClientProxyProtocol {
    var supportsCHIICHDeletion: Bool { false }
    func makeCHIICHDeletionService() -> CHIICHDeletionService? { nil }
}
