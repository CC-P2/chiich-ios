// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation
import MatrixRustSDK

nonisolated enum CHIICHPasswordCapability: Equatable, Sendable {
    case allowed
    case disabled
    case unknown
}

nonisolated enum CHIICHPasswordError: Error, Equatable, Sendable {
    case invalidPassword
    case passwordsDoNotMatch
    case passwordTooLong
    case passwordPolicy
    case currentPasswordRequired
    case authenticationRejected
    case authenticationIncomplete
    case unsupportedAuthentication
    case unsupportedServer
    case serverDisabled
    case sessionChanged
    case expiredChallenge
    case rateLimited
    case invalidResponse
    case outcomeUnknown
    case cancelled
    case matrixUnknownToken(softLogout: Bool)
}

/// No token or password belongs in a screen's identity or its browser URL.
nonisolated struct CHIICHPasswordContext: Equatable, Sendable {
    let accountID: String
    let deviceID: String
    let origin: URL

    init?(accountID: String, deviceID: String, homeserver: String) {
        guard accountID.utf8.count <= 1024,
              accountID.hasSuffix(":chat.chiich.one"),
              accountID.range(of: "^@[^\\s:]+:chat\\.chiich\\.one$", options: .regularExpression) != nil,
              !deviceID.isEmpty, deviceID.utf8.count <= 255,
              let components = URLComponents(string: homeserver),
              components.scheme == "https", let host = components.host?.lowercased(),
              ["matrix.chiich.one", "chiich-matrix.onrender.com"].contains(host),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              let origin = URL(string: "https://\(host)") else { return nil }
        self.accountID = accountID
        self.deviceID = deviceID
        self.origin = origin
    }

    func ssoURL(session: String) -> URL? {
        guard CHIICHPasswordChallenge.isValidSession(session),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/_matrix/client/v3/auth/m.login.sso/fallback/web"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url
    }
}

nonisolated enum CHIICHPasswordAuth: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    // Reuse the SDK's password UIA value. The FFI has no general UIA/set-password API.
    case password(AuthDataPasswordDetails)
    case session(String)

    var sessionID: String {
        switch self {
        case .password(let details): details.session
        case .session(let session): session
        }
    }

    var description: String { "CHIICHPasswordAuth(<redacted>)" }
    var debugDescription: String { description }
}

/// Never persist a request; redact even accidental diagnostic descriptions.
nonisolated struct CHIICHPasswordRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let newPassword: String
    let authentication: CHIICHPasswordAuth?

    var description: String { "CHIICHPasswordRequest(<redacted>)" }
    var debugDescription: String { description }

    static func validationError(newPassword: String, confirmation: String) -> CHIICHPasswordError? {
        guard !newPassword.isEmpty else { return .invalidPassword }
        guard newPassword.unicodeScalars.count <= 512 else { return .passwordTooLong }
        // Swift String equality is canonically equivalent; passwords must match byte-for-byte.
        guard newPassword.utf8.elementsEqual(confirmation.utf8) else { return .passwordsDoNotMatch }
        return nil
    }

    func urlRequest(context: CHIICHPasswordContext) throws -> URLRequest {
        guard !newPassword.isEmpty else { throw CHIICHPasswordError.invalidPassword }
        guard newPassword.unicodeScalars.count <= 512 else { throw CHIICHPasswordError.passwordTooLong }
        var body: [String: Any] = ["new_password": newPassword, "logout_devices": false]
        if let authentication {
            guard CHIICHPasswordChallenge.isValidSession(authentication.sessionID) else { throw CHIICHPasswordError.expiredChallenge }
            switch authentication {
            case .password(let details):
                guard details.identifier.utf8.elementsEqual(context.accountID.utf8), !details.password.isEmpty else { throw CHIICHPasswordError.currentPasswordRequired }
                guard details.password.unicodeScalars.count <= 512 else { throw CHIICHPasswordError.passwordTooLong }
                body["auth"] = ["type": "m.login.password",
                                "identifier": ["type": "m.id.user", "user": context.accountID],
                                "password": details.password,
                                "session": details.session]
            case .session(let session):
                body["auth"] = ["session": session]
            }
        }
        var request = URLRequest(url: context.origin.appending(path: "_matrix/client/v3/account/password"),
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

nonisolated struct CHIICHPasswordChallenge: Decodable, Equatable, Sendable {
    nonisolated struct Flow: Decodable, Equatable, Sendable {
        let stages: [String]
    }

    nonisolated enum Stage: String, Hashable, Sendable {
        case password = "m.login.password"
        case sso = "m.login.sso"
    }

    let session: String
    let flows: [Flow]
    let completed: [String]?
    let errcode: String?

    static func isValidSession(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    var isValid: Bool {
        Self.isValidSession(session) && !flows.isEmpty && flows.count <= 16
            && flows.allSatisfy { !$0.stages.isEmpty && $0.stages.count <= 8 && $0.stages.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 } }
            && (completed?.count ?? 0) <= 32
            && (completed?.allSatisfy { $0.utf8.count <= 128 } ?? true)
    }

    private var remainingFlows: [[String]] {
        let completed = Set(completed ?? [])
        return flows.map { $0.stages.filter { !completed.contains($0) } }
    }

    /// Only use a flow the app can finish. Unknown UIA is never treated as password/SSO.
    var availableStages: Set<Stage> {
        Set(remainingFlows.filter { $0.allSatisfy { Stage(rawValue: $0) != nil } }.compactMap { $0.first.flatMap(Stage.init(rawValue:)) })
    }

    var isComplete: Bool {
        remainingFlows.contains(where: \.isEmpty)
    }

    var canContinue: Bool {
        isComplete || !availableStages.isEmpty
    }
}

nonisolated enum CHIICHPasswordResponse: Equatable, Sendable {
    case success
    case challenge(CHIICHPasswordChallenge)
}

/// The nonce belongs to this presentation and this pending UIA attempt, never a login callback.
nonisolated struct CHIICHPasswordSSOPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
}

nonisolated enum CHIICHPasswordSessionBinding {
    static func matches(current: Session, initiating: Session, homeserver: String, initiatingHomeserver: String, isActive: Bool) -> Bool {
        guard isActive, current.oauthData == nil, initiating.oauthData == nil,
              homeserver.utf8.elementsEqual(initiatingHomeserver.utf8) else { return false }
        return current == initiating
            && current.userId.utf8.elementsEqual(initiating.userId.utf8)
            && current.deviceId.utf8.elementsEqual(initiating.deviceId.utf8)
            && current.accessToken.utf8.elementsEqual(initiating.accessToken.utf8)
            && current.homeserverUrl.utf8.elementsEqual(initiating.homeserverUrl.utf8)
    }
}
