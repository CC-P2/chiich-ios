//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct SSOCallbackTests {
    @Test
    func callbackIsBoundToOneAttempt() throws {
        let callback = try #require(SSOCallback(scheme: "one.chiich.app"))
        #expect(callback.accepts(URL(string: callback.url.absoluteString + "?loginToken=test-only")!))
        let another = try #require(SSOCallback(scheme: "one.chiich.app"))
        #expect(!callback.accepts(another.url))
        #expect(!callback.accepts(URL(string: callback.url.absoluteString.replacingOccurrences(of: "one.chiich.app:", with: "other:"))!))
        #expect(!callback.accepts(URL(string: callback.url.absoluteString.replacingOccurrences(of: "://sso/", with: "://elsewhere/"))!))
        #expect(!callback.accepts(URL(string: callback.url.absoluteString + "/suffix?loginToken=test-only")!))
        #expect(!callback.accepts(URL(string: callback.url.absoluteString + "#fragment")!))
        #expect(!callback.accepts(URL(string: callback.url.absoluteString.replacingOccurrences(of: "://sso/", with: "://user@sso/"))!))
        #expect(!callback.accepts(URL(string: callback.url.absoluteString.replacingOccurrences(of: "://sso/", with: "://sso:123/"))!))
    }
}

@MainActor
struct SSOAuthenticationTests {
    private var service: AuthenticationService
    private var client: ClientSDKMock
    private var handler: SsoHandlerSDKMock
    private var manager: UserSessionManagerMock

    init() throws {
        let configuration = ClientFactoryMock.Configuration()
        client = try #require(configuration.homeserverClients["example.com"])
        let details = try #require(client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock)
        details.supportsSsoLoginReturnValue = true
        client.userIdReturnValue = "@alice:example.com"
        handler = SsoHandlerSDKMock()
        handler.urlReturnValue = "https://matrix.example.com/_matrix/client/v3/login/sso/redirect/oidc-apple"
        client.startSsoLoginRedirectUrlIdpIdReturnValue = handler
        manager = UserSessionManagerMock(.init())
        service = AuthenticationService(userSessionManager: manager,
                                        encryptionKeyProvider: MockEncryptionKeyProvider(),
                                        classicAppManager: nil,
                                        clientFactory: ClientFactoryMock(configuration),
                                        appSettings: .volatile(),
                                        appHooks: AppHooks())
    }

    private func begin(_ provider: SSOIdentityProvider = .apple) async throws -> SSOLoginRequest {
        try await service.configure(for: "example.com", flow: .login).get()
        let callback = try #require(SSOCallback(scheme: "one.chiich.app"))
        return try await service.beginSSOLogin(provider: provider, callback: callback).get()
    }

    private func callbackURL(_ request: SSOLoginRequest) -> URL {
        // Dummy value; tests never contact a server or consume real credentials.
        URL(string: request.callback.url.absoluteString + "?loginToken=test-only")!
    }

    @Test(arguments: [AuthenticationFlow.login, .register])
    func ssoSupportsSignInAndFirstSignInRegistration(flow: AuthenticationFlow) async throws {
        try await service.configure(for: "example.com", flow: flow).get()
        #expect(service.homeserver.value.loginMode == .sso)
        #expect(service.flow == flow)
    }

    @Test(arguments: SSOIdentityProvider.allCases)
    func nativeProviderAndCallbackArePassedToSDK(provider: SSOIdentityProvider) async throws {
        let request = try await begin(provider)
        #expect(client.startSsoLoginRedirectUrlIdpIdReceivedArguments?.idpId == provider.rawValue)
        #expect(client.startSsoLoginRedirectUrlIdpIdReceivedArguments?.redirectUrl == request.callback.url.absoluteString)
    }

    @Test
    func successfulLoginUsesNativeSessionManagerOnce() async throws {
        let request = try await begin()
        _ = try await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: nil).get()
        #expect(handler.finishCallbackUrlCallsCount == 1)
        #expect(manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
        let duplicate = await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: nil)
        #expect(duplicate.failure == .ssoError(.cancelled))
        #expect(handler.finishCallbackUrlCallsCount == 1)
    }

    @Test
    func wrongCallbackNeverReachesSDK() async throws {
        let request = try await begin()
        let wrong = try #require(SSOCallback(scheme: "one.chiich.app"))
        let result = await service.finishSSOLogin(requestID: request.id, callbackURL: wrong.url, expectedUserID: nil)
        #expect(result.failure == .ssoError(.invalidCallback))
        #expect(handler.finishCallbackUrlCallsCount == 0)
        #expect(manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test
    func staleCallbackAndCancellationCannotAffectNextAttempt() async throws {
        let old = try await begin()
        #expect(service.cancelSSOLogin(requestID: old.id))
        let current = try await begin(.google)
        #expect(service.cancelSSOLogin(requestID: old.id))
        let stale = await service.finishSSOLogin(requestID: old.id, callbackURL: callbackURL(old), expectedUserID: nil)
        #expect(stale.failure == .ssoError(.cancelled))
        _ = try await service.finishSSOLogin(requestID: current.id, callbackURL: callbackURL(current), expectedUserID: nil).get()
        #expect(handler.finishCallbackUrlCallsCount == 1)
    }

    @Test
    func duplicateDuringExchangeCannotExchangeTwiceOrReconfigure() async throws {
        let request = try await begin()
        let gate = SSOTestGate()
        handler.finishCallbackUrlClosure = { _ in await gate.suspend() }
        let operation = Task { await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: nil) }
        await gate.waitUntilEntered()
        let duplicate = await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: nil)
        #expect(duplicate.failure == .ssoError(.cancelled))
        let reconfigure = await service.configure(for: "matrix.org", flow: .login)
        #expect(reconfigure.failure == .ssoError(.unavailable))
        await gate.release()
        _ = try await operation.value.get()
        #expect(handler.finishCallbackUrlCallsCount == 1)
    }

    @Test
    func cancellationDuringExchangeNeverPersistsSession() async throws {
        let request = try await begin()
        let gate = SSOTestGate()
        handler.finishCallbackUrlClosure = { _ in await gate.suspend() }
        let operation = Task { await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: nil) }
        await gate.waitUntilEntered()
        #expect(service.cancelSSOLogin(requestID: request.id))
        await gate.release()
        #expect(await operation.value.failure == .ssoError(.cancelled))
        #expect(manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
        #expect(client.logoutCallsCount == 1)
    }

    @Test
    func cancelledBeginCanBeRetried() async throws {
        try await service.configure(for: "example.com", flow: .login).get()
        let gate = SSOTestGate()
        let handler = handler
        client.startSsoLoginRedirectUrlIdpIdClosure = { _, _ in
            await gate.suspend()
            return handler
        }
        let callback = try #require(SSOCallback(scheme: "one.chiich.app"))
        let operation = Task { await service.beginSSOLogin(provider: .apple, callback: callback) }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        #expect(await operation.value.failure == .ssoError(.cancelled))
        client.startSsoLoginRedirectUrlIdpIdClosure = nil
        _ = try await begin(.google)
    }

    @Test
    func wrongSoftLogoutAccountIsNotPersisted() async throws {
        let request = try await begin()
        let result = await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: "@different:example.com")
        #expect(result.failure == .invalidCredentials)
        #expect(manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
        #expect(client.logoutCallsCount == 1)
    }

    @Test
    func nativeCommitIsDeliveredInsteadOfDiscardedOnCancellation() async throws {
        let request = try await begin()
        let gate = SSOTestGate()
        let session = UserSessionMock(.init())
        manager.userSessionForSessionDirectoriesPassphraseClosure = { _, _, _ in
            await gate.suspend()
            return .success(session)
        }
        let operation = Task { await service.finishSSOLogin(requestID: request.id, callbackURL: callbackURL(request), expectedUserID: nil) }
        await gate.waitUntilEntered()
        #expect(!service.cancelSSOLogin(requestID: request.id))
        service.reset()
        #expect(service.homeserver.value.loginMode == .sso)
        await gate.release()
        _ = try await operation.value.get()
        #expect(manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private actor SSOTestGate {
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
