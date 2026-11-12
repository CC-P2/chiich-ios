// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CHIICHPasswordLoginResolverTests {
    @Test(arguments: ["https://matrix.chiich.one", "https://chiich-matrix.onrender.com/", "https://matrix.chiich.one:443"])
    func publicLookupHasNoCredentialsOrMutation(_ homeserver: String) async throws {
        let fixture = CHIICHUsernameLookupFixture()
        let identifier = try await fixture.resolver.resolve(username: "ИВАН123", homeserver: homeserver)

        #expect(identifier == .init(username: CHIICHUsernameLookupFixture.userID, expectedUserID: CHIICHUsernameLookupFixture.userID))
        let request = try #require(fixture.requests.first)
        #expect(fixture.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path(percentEncoded: false) == "/_synapse/client/chiich/username/иван123")
        #expect(request.url?.query == nil)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test
    func retiredAliasKeepsItsOwnersImmutableAccount() async throws {
        let fixture = CHIICHUsernameLookupFixture()
        // The returned current name deliberately differs from the historical input.
        let identifier = try await fixture.resolver.resolve(username: "oldname", homeserver: Self.homeserver)
        #expect(identifier.username == CHIICHUsernameLookupFixture.userID)
        #expect(identifier.expectedUserID == CHIICHUsernameLookupFixture.userID)
    }

    @Test(arguments: ["@existing=40email:chat.chiich.one", "@someone:example.com", "legacy_name", "a", "admin", "existing@email.invalid",
                      " Alice", "Alice ", "ＡＬＩＣＥ", "Е\u{0308}жик"])
    func matrixIDsAndHistoricalLocalpartsKeepTheNativePath(_ username: String) async throws {
        let fixture = CHIICHUsernameLookupFixture()
        let identifier = try await fixture.resolver.resolve(username: username, homeserver: Self.homeserver)
        #expect(identifier == .init(username: username, expectedUserID: nil))
        #expect(fixture.requests.isEmpty)
    }

    @Test(arguments: ["https://matrix.example.com", "http://matrix.chiich.one", "https://matrix.chiich.one.evil.invalid",
                      "https://matrix.chiich.one/path", "https://matrix.chiich.one?token=synthetic", "https://matrix.chiich.one#fragment",
                      "https://user@matrix.chiich.one", "https://matrix.chiich.one:8448"])
    func otherOriginsNeverReceiveTheAliasLookup(_ homeserver: String) async throws {
        let fixture = CHIICHUsernameLookupFixture()
        let identifier = try await fixture.resolver.resolve(username: "Alice", homeserver: homeserver)
        #expect(identifier == .init(username: "Alice", expectedUserID: nil))
        #expect(fixture.requests.isEmpty)
    }

    @Test
    func authoritativeNotFoundPreservesTheTypedLegacyUsername() async throws {
        let fixture = CHIICHUsernameLookupFixture(result: .failure(.notFound))
        let identifier = try await fixture.resolver.resolve(username: "Alice", homeserver: Self.homeserver)
        #expect(identifier == .init(username: "Alice", expectedUserID: nil))
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [CHIICHIdentityError.rateLimited, .unavailable, .uncertain, .invalidResponse, .cancelled, .matrixUnknownToken(softLogout: true)])
    func lookupErrorsCannotBecomeALegacyPasswordAttempt(_ error: CHIICHIdentityError) async {
        let fixture = CHIICHUsernameLookupFixture(result: .failure(error))
        await #expect(throws: error) {
            try await fixture.resolver.resolve(username: "Alice", homeserver: Self.homeserver)
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: ["@someone:evil.invalid", "@someone:chat.chiich.one.evil.invalid", "someone:chat.chiich.one",
                      "@person\n:chat.chiich.one", "@person:chat.chiich.one\n", "@:chat.chiich.one"])
    func resolvedAccountMustBeAnExactOwnedMatrixID(_ userID: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["username": "newname", "user_id": userID])
        let fixture = CHIICHUsernameLookupFixture(result: .success(data))
        await #expect(throws: CHIICHIdentityError.invalidResponse) {
            try await fixture.resolver.resolve(username: "Alice", homeserver: Self.homeserver)
        }
    }

    @Test(arguments: [Data(), Data("not json".utf8), Data("{\"username\":\"alice\"}".utf8),
                      Data("{\"username\":false,\"user_id\":\"@alice:chat.chiich.one\"}".utf8), Data(count: 16_385)])
    func malformedOrOversizedRepliesCannotBecomeCredentials(_ data: Data) async {
        let fixture = CHIICHUsernameLookupFixture(result: .success(data))
        await #expect(throws: CHIICHIdentityError.invalidResponse) {
            try await fixture.resolver.resolve(username: "Alice", homeserver: Self.homeserver)
        }
    }

    private static let homeserver = "https://matrix.chiich.one"
}

@MainActor
final class CHIICHUsernameLookupFixture {
    static let userID = "@existing=40email:chat.chiich.one"
    static let response = Data("{\"username\":\"newname\",\"user_id\":\"@existing=40email:chat.chiich.one\"}".utf8)

    var result: Result<Data, CHIICHIdentityError>
    var requests = [URLRequest]()
    var gate: CHIICHUsernameLookupGate?

    init(result: Result<Data, CHIICHIdentityError> = .success(CHIICHUsernameLookupFixture.response)) {
        self.result = result
    }

    var resolver: CHIICHPasswordLoginResolver {
        CHIICHPasswordLoginResolver { request in
            self.requests.append(request)
            if let gate = self.gate { await gate.suspend() }
            return self.result
        }
    }
}

actor CHIICHUsernameLookupGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
