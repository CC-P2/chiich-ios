// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

nonisolated enum CHIICHIdentityError: Error, Equatable {
    case invalidUsername, conflict, aliasLimit, rateLimited, notFound
    case unavailable, invalidResponse, sessionChanged, cancelled, uncertain
    case matrixUnknownToken(softLogout: Bool)
}

/// A mutable public name for an unchanged Matrix account. Authentication stays in the native SDK.
nonisolated struct CHIICHPublicUsername: Hashable, Sendable {
    let value: String

    /// Ownership is case-insensitive; a chosen name keeps the user's spelling.
    var canonicalValue: String { value.lowercased(with: Locale(identifier: "en_US_POSIX")) }

    static let reserved: Set<String> = Set("""
    admin administrator administrators support help official chiich element matrix www api
    login logout register signup signin account accounts settings profile user users username
    usernames invite invitations home app apps assets bundles config diagnostics health status
    static wellknown index shortlink
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    var link: URL {
        let origin: URL = "https://chiich.one"
        return origin.appending(path: value)
    }

    var displayLink: String { "chiich.one/\(value)" }

    var appLink: URL {
        let origin: URL = "one.chiich.app://user"
        return origin.appending(path: value)
    }

    init(_ input: String) throws {
        guard input.unicodeScalars.count <= 96 else { throw CHIICHIdentityError.invalidUsername }
        let normalised = input.precomposedStringWithCompatibilityMapping
        let scalars = normalised.unicodeScalars
        guard (3...24).contains(scalars.count), scalars.allSatisfy(Self.isAllowed) else {
            throw CHIICHIdentityError.invalidUsername
        }
        let lowercased = normalised.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let hasLatin = lowercased.unicodeScalars.contains { (97...122).contains($0.value) }
        let hasCyrillic = lowercased.unicodeScalars.contains { (1072...1103).contains($0.value) || $0.value == 1105 }
        guard !(hasLatin && hasCyrillic), !Self.reserved.contains(lowercased) else {
            throw CHIICHIdentityError.invalidUsername
        }
        value = lowercased
    }

    /// New choices reject unsupported input instead of silently rewriting it.
    /// The ordinary initializer remains compatible with existing invitation URLs.
    init(chosen input: String) throws {
        guard (3...24).contains(input.unicodeScalars.count), input.unicodeScalars.allSatisfy(Self.isAllowed) else {
            throw CHIICHIdentityError.invalidUsername
        }
        _ = try Self(input)
        value = input
    }

    static func fromInvitationURL(_ url: URL) -> Self? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              components.path.hasPrefix("/") else { return nil }
        switch (components.scheme, components.host?.lowercased()) {
        case ("https", "chiich.one"):
            guard components.port == nil || components.port == 443 else { return nil }
        case ("one.chiich.app", "user"):
            guard components.port == nil else { return nil }
        default:
            return nil
        }
        return try? Self(String(components.path.dropFirst()))
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            || (1040...1103).contains(scalar.value) || scalar.value == 1025 || scalar.value == 1105
    }
}

nonisolated enum CHIICHIdentityRequest: Equatable, Sendable {
    case current
    case rename(CHIICHPublicUsername)
    case resolve(CHIICHPublicUsername)

    func urlRequest(homeserver: String) throws -> URLRequest {
        guard var components = URLComponents(string: homeserver), components.scheme == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, ["matrix.chiich.one", "chiich-matrix.onrender.com"].contains(host) else {
            throw CHIICHIdentityError.unavailable
        }
        components.path = "/_synapse/client/chiich/username"
        if case .resolve(let username) = self {
            components.path += "/\(username.canonicalValue)"
        } else {
            components.queryItems = [URLQueryItem(name: "selection", value: "explicit")]
        }
        guard let url = components.url else { throw CHIICHIdentityError.unavailable }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch self {
        case .current, .resolve:
            request.httpMethod = "GET"
        case .rename(let username):
            request.httpMethod = "PUT"
            request.httpBody = try JSONEncoder().encode(["username": username.value])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

nonisolated struct CHIICHIdentityResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case username
        case displayUsername = "display_username"
    }

    let username: String?
    let displayUsername: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.username), values.contains(.displayUsername) else {
            throw CHIICHIdentityError.invalidResponse
        }
        username = try values.decodeIfPresent(String.self, forKey: .username)
        displayUsername = try values.decodeIfPresent(String.self, forKey: .displayUsername)
    }

    func validated() throws -> CHIICHPublicUsername? {
        if username == nil, displayUsername == nil { return nil }
        guard let username, let displayUsername else { throw CHIICHIdentityError.invalidResponse }
        let alias = try CHIICHPublicUsername(chosen: displayUsername)
        guard alias.canonicalValue == username else { throw CHIICHIdentityError.invalidResponse }
        return alias
    }
}

nonisolated struct CHIICHIdentityRecipient: Decodable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case username
        case userID = "user_id"
    }

    let username: String
    let userID: String

    func validated() throws -> Self {
        guard try CHIICHPublicUsername(username).value == username else { throw CHIICHIdentityError.invalidResponse }
        guard Self.isOwnedUserID(userID) else { throw CHIICHIdentityError.invalidResponse }
        return self
    }

    static func isOwnedUserID(_ userID: String) -> Bool {
        userID.utf8.count <= 255 && userID.range(of: "\\A@[^\\s:\\p{C}]+:chat\\.chiich\\.one\\z", options: .regularExpression) != nil
    }
}
