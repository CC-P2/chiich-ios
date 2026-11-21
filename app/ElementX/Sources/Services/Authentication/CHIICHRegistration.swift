// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

enum CHIICHRegistration {
    nonisolated enum Reply: Sendable {
        case created(String)
        case challenge(CHIICHPasswordChallenge)
        case rejected(String)
    }

    typealias Send = (URLRequest) async -> Result<Reply, CHIICHPasswordError>

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "CHIICHRegistration", comment: "")
    }

    static func create(username: String, password: String, invitation: String,
                       send: Send = { await CHIICHPasswordHTTP.send($0, classifier: classify) }) async -> Reply {
        let invitationStage = "m.login.registration_token"
        let dummyStage = "m.login.dummy"
        var authentication: [String: String]?
        var sessionID: String?
        var sent = Set<String>()
        let expectedID = "@\(username):chat.chiich.one"
        while !Task.isCancelled {
            var request = URLRequest(url: URL(string: "https://matrix.chiich.one/_matrix/client/v3/register")!,
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            var body: [String: Any] = ["username": username, "password": password, "inhibit_login": true]
            if let authentication { body["auth"] = authentication }
            guard let bytes = try? JSONSerialization.data(withJSONObject: body) else { return .rejected("invalid") }
            request.httpBody = bytes
            switch await send(request) {
            case .failure:
                return .rejected("uncertain")
            case .success(.created(let userID)):
                guard userID == expectedID else { return .rejected("uncertain") }
                return .created(userID)
            case .success(.rejected(let key)):
                return .rejected(key)
            case .success(.challenge(let challenge)):
                guard challenge.isValid, sessionID == nil || challenge.session == sessionID else { return .rejected("unsupported") }
                sessionID = challenge.session
                let completed = Set(challenge.completed ?? [])
                let remaining = challenge.flows.map { $0.stages.filter { !completed.contains($0) } }
                guard let stage = remaining.first(where: { !$0.isEmpty && $0.allSatisfy { $0 == invitationStage || $0 == dummyStage } })?.first
                else { return .rejected("unsupported") }
                guard sent.insert(stage).inserted else { return .rejected(stage == invitationStage ? "bad_invite" : "unsupported") }
                authentication = ["type": stage, "session": challenge.session]
                if stage == invitationStage {
                    guard !invitation.isEmpty else { return .rejected("invite_needed") }
                    authentication?["token"] = invitation
                }
            }
        }
        return .rejected("uncertain")
    }

    nonisolated static func classify(_ data: Data, _ status: Int) -> Result<Reply, CHIICHPasswordError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.outcomeUnknown) }
        let code = object["errcode"] as? String
        switch (status, code) {
        case (200, nil):
            guard let id = object["user_id"] as? String else { return .failure(.outcomeUnknown) }
            return .success(.created(id))
        case (401, nil):
            guard let challenge = try? JSONDecoder().decode(CHIICHPasswordChallenge.self, from: data), challenge.isValid
            else { return .success(.rejected("unsupported")) }
            return .success(.challenge(challenge))
        case (_, "M_USER_IN_USE"), (_, "M_EXCLUSIVE"): return .success(.rejected("taken"))
        case (_, "M_INVALID_USERNAME"): return .success(.rejected("invalid"))
        case (_, "M_LIMIT_EXCEEDED"), (429, _): return .success(.rejected("rate_limit"))
        case (401, "M_FORBIDDEN"), (401, "M_UNAUTHORIZED"), (400, "M_UNAUTHORIZED"): return .success(.rejected("bad_invite"))
        case (403, _): return .success(.rejected("server_refused"))
        default:
            if let code, code == "M_WEAK_PASSWORD" || code.hasPrefix("M_PASSWORD_") { return .success(.rejected("weak")) }
            return .failure(.outcomeUnknown)
        }
    }
}
