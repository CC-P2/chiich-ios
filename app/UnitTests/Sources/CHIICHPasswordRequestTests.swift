// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

struct CHIICHPasswordRequestTests {
    private static let account = "@alice:chat.chiich.one"

    @Test(arguments: ["https://matrix.chiich.one", "https://chiich-matrix.onrender.com/", "https://matrix.chiich.one:443"])
    func onlyOwnedOriginsProduceTheStandardPasswordEndpoint(_ origin: String) throws {
        let context = try #require(CHIICHPasswordContext(accountID: Self.account, deviceID: "TEST-DEVICE", homeserver: origin))
        let request = try CHIICHPasswordRequest(newPassword: "test-new-only", authentication: nil).urlRequest(context: context)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/_matrix/client/v3/account/password")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try Self.body(request)
        #expect(body["logout_devices"] as? Bool == false)
        #expect(body["new_password"] as? String == "test-new-only")
        #expect(body["auth"] == nil)
    }

    @Test(arguments: ["https://matrix.org", "http://matrix.chiich.one", "https://matrix.chiich.one.evil.invalid",
                      "https://user:password@matrix.chiich.one", "https://matrix.chiich.one/path",
                      "https://matrix.chiich.one?next=elsewhere", "https://matrix.chiich.one#fragment", "https://matrix.chiich.one:8448"])
    func foreignOrAmbiguousOriginsCannotReceivePasswords(_ origin: String) {
        #expect(CHIICHPasswordContext(accountID: Self.account, deviceID: "TEST-DEVICE", homeserver: origin) == nil)
    }

    @Test(arguments: ["@alice:matrix.org", "@alice:chat.chiich.one\n", "alice", "@:chat.chiich.one"])
    func foreignOrMalformedAccountsCannotCreateAContext(_ account: String) {
        #expect(CHIICHPasswordContext(accountID: account, deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one") == nil)
    }

    @Test
    func passwordUIAUsesTheInitiatingAccountAndPreservesWhitespace() throws {
        let context = try #require(CHIICHPasswordContext(accountID: Self.account, deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one"))
        let request = try CHIICHPasswordRequest(newPassword: " new-test-only ",
                                               authentication: .password(.init(identifier: Self.account, password: " old-test-only ", session: "uia-test-only")))
            .urlRequest(context: context)
        let body = try Self.body(request)
        let auth = try #require(body["auth"] as? [String: Any])
        #expect(body["new_password"] as? String == " new-test-only ")
        #expect(body["logout_devices"] as? Bool == false)
        #expect(auth["type"] as? String == "m.login.password")
        #expect(auth["password"] as? String == " old-test-only ")
        #expect(auth["session"] as? String == "uia-test-only")
        #expect((auth["identifier"] as? [String: String]) == ["type": "m.id.user", "user": Self.account])
    }

    @Test
    func anotherAccountCannotBeUsedToSatisfyPasswordUIA() throws {
        let context = try #require(CHIICHPasswordContext(accountID: Self.account, deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one"))
        let request = CHIICHPasswordRequest(newPassword: "new-test-only",
                                            authentication: .password(.init(identifier: "@bob:chat.chiich.one", password: "old-test-only", session: "uia-test-only")))
        #expect(throws: CHIICHPasswordError.currentPasswordRequired) { try request.urlRequest(context: context) }
    }

    @Test
    func ssoCompletionResubmitsOnlyItsSessionAsAuthAndKeepsDevices() throws {
        let context = try #require(CHIICHPasswordContext(accountID: Self.account, deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one"))
        let request = try CHIICHPasswordRequest(newPassword: "new-test-only", authentication: .session("uia-test-only")).urlRequest(context: context)
        let body = try Self.body(request)
        #expect((body["auth"] as? [String: String]) == ["session": "uia-test-only"])
        #expect(body["logout_devices"] as? Bool == false)
    }

    @Test
    func fallbackURLContainsOnlyTheEncodedServerSession() throws {
        let context = try #require(CHIICHPasswordContext(accountID: Self.account, deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one"))
        let session = "test-only/+&other=value#fragment"
        let url = try #require(context.ssoURL(session: session))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.path == "/_matrix/client/v3/auth/m.login.sso/fallback/web")
        #expect(components.queryItems == [URLQueryItem(name: "session", value: session)])
        #expect(url.fragment == nil)
    }

    @Test
    func passwordConfirmationMustMatchBytesNotCanonicalUnicodeEquivalence() {
        #expect(CHIICHPasswordRequest.validationError(newPassword: "test-\u{00E9}", confirmation: "test-e\u{0301}") == .passwordsDoNotMatch)
        #expect(CHIICHPasswordRequest.validationError(newPassword: "", confirmation: "") == .invalidPassword)
        #expect(CHIICHPasswordRequest.validationError(newPassword: String(repeating: "a", count: 513), confirmation: String(repeating: "a", count: 513)) == .passwordTooLong)
    }

    @Test
    func uiAChallengeIsNotConfusedWithExpiredAccessToken() throws {
        let data = try Self.json(["session": "uia-test-only", "flows": [["stages": ["m.login.password"]]], "errcode": "M_FORBIDDEN"])
        let result = CHIICHPasswordHTTP.classify(data: data, statusCode: 401)
        guard case .success(.challenge(let challenge)) = result else {
            Issue.record("Expected the server's UIA challenge, not logout or success.")
            return
        }
        #expect(challenge.availableStages == [.password])
        let tokenError = try Self.json(["errcode": "M_UNKNOWN_TOKEN", "soft_logout": true])
        #expect(CHIICHPasswordHTTP.classify(data: tokenError, statusCode: 401) == .failure(.matrixUnknownToken(softLogout: true)))
        #expect(CHIICHPasswordHTTP.classify(data: tokenError, statusCode: 403) == .failure(.authenticationRejected))
    }

    @Test
    func malformedOrOversizedResponsesNeverReportSuccess() throws {
        #expect(CHIICHPasswordHTTP.classify(data: Data("not JSON".utf8), statusCode: 200) == .failure(.outcomeUnknown))
        #expect(CHIICHPasswordHTTP.classify(data: try Self.json(["errcode": "M_FORBIDDEN"]), statusCode: 200) == .failure(.outcomeUnknown))
        #expect(CHIICHPasswordHTTP.classify(data: Data(repeating: 32, count: 64_001), statusCode: 200) == .failure(.outcomeUnknown))
        #expect(CHIICHPasswordHTTP.classify(data: try Self.json(["session": "", "flows": []]), statusCode: 401) == .failure(.invalidResponse))
        #expect(CHIICHPasswordHTTP.classify(data: Data("{}".utf8), statusCode: 200) == .success(.success))
        #expect(CHIICHPasswordHTTP.classify(data: Data("{}".utf8), statusCode: 302) == .failure(.outcomeUnknown))
    }

    @Test
    func policyAndRateLimitErrorsRemainExplicitAndNonRetrying() throws {
        #expect(CHIICHPasswordHTTP.classify(data: try Self.json(["errcode": "M_PASSWORD_TOO_SHORT"]), statusCode: 400) == .failure(.passwordPolicy))
        #expect(CHIICHPasswordHTTP.classify(data: try Self.json(["errcode": "M_LIMIT_EXCEEDED"]), statusCode: 429) == .failure(.rateLimited))
    }

    @Test
    func requestDiagnosticsCannotRevealEitherPasswordOrUIASession() {
        let auth = CHIICHPasswordAuth.password(.init(identifier: Self.account, password: "old-test-only", session: "uia-test-only"))
        let request = CHIICHPasswordRequest(newPassword: "new-test-only", authentication: auth)
        for description in [String(describing: request), String(reflecting: request), String(describing: auth), String(reflecting: auth)] {
            #expect(!description.contains("old-test-only"))
            #expect(!description.contains("new-test-only"))
            #expect(!description.contains("uia-test-only"))
        }
    }

    @Test
    func accountDeviceTokenOriginAndLogoutAreBoundToTheInitiatingSession() {
        let origin = "https://matrix.chiich.one"
        let initiating = Session(accessToken: "token-test-only", refreshToken: nil, userId: Self.account, deviceId: "DEVICE-TEST",
                                 homeserverUrl: origin, oauthData: nil, slidingSyncVersion: .native)
        func matches(_ current: Session, homeserver: String? = nil, active: Bool = true) -> Bool {
            CHIICHPasswordSessionBinding.matches(current: current, initiating: initiating, homeserver: homeserver ?? origin,
                                                 initiatingHomeserver: origin, isActive: active)
        }
        #expect(matches(initiating))
        #expect(!matches(initiating, active: false))
        #expect(!matches(initiating, homeserver: "https://chiich-matrix.onrender.com"))
        var changed = initiating
        changed.userId = "@bob:chat.chiich.one"
        #expect(!matches(changed))
        changed = initiating
        changed.deviceId = "DIFFERENT-DEVICE"
        #expect(!matches(changed))
        changed = initiating
        changed.accessToken = "rotated-token-test-only"
        #expect(!matches(changed))
        changed = initiating
        changed.oauthData = "test-only"
        #expect(!matches(changed))
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
