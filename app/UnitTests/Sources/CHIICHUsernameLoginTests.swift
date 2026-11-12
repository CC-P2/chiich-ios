// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CHIICHUsernameLoginTests {
    @Test
    func aliasUsesOnlyTheExistingSDKPasswordAndSessionFlow() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        try await fixture.configure()
        _ = try await fixture.login(username: "ИВАН123").get()

        let arguments = try #require(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdReceivedArguments)
        #expect(arguments.username == CHIICHUsernameLookupFixture.userID)
        #expect(arguments.password == CHIICHUsernameLoginFixture.password)
        #expect(arguments.initialDeviceName == "Synthetic iPhone")
        #expect(arguments.deviceId == "EXISTINGDEVICE")
        #expect(fixture.lookup.requests.count == 1)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)
    }

    @Test
    func fullMatrixIDForSoftLogoutBypassesThePublicLookup() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        try await fixture.configure()
        _ = try await fixture.login(username: CHIICHUsernameLookupFixture.userID).get()

        #expect(fixture.lookup.requests.isEmpty)
        let arguments = try #require(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdReceivedArguments)
        #expect(arguments.username == CHIICHUsernameLookupFixture.userID)
        #expect(arguments.deviceId == "EXISTINGDEVICE")
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test
    func unknownAliasMakesOneLegacyLoginAttemptWithoutCreatingAnAccount() async throws {
        let fixture = CHIICHUsernameLoginFixture(lookup: .init(result: .failure(.notFound)))
        try await fixture.configure()
        // An existing historical localpart can still authenticate through the SDK.
        fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { username, _, _, _ in
            #expect(username == "Alice")
        }
        _ = try await fixture.login(username: "Alice").get()

        #expect(fixture.lookup.requests.count == 1)
        #expect(fixture.lookup.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test
    func rejectedUnknownAliasDoesNotCommitOrRetry() async throws {
        let fixture = CHIICHUsernameLoginFixture(lookup: .init(result: .failure(.notFound)))
        try await fixture.configure()
        #expect(await fixture.login(username: "unknown").usernameLoginFailure != nil)
        await Task.yield()

        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
        #expect(fixture.lookup.requests.count == 1)
    }

    @Test
    func networkFailureNeverSendsThePasswordAndReleasesTheLockForRetry() async throws {
        let fixture = CHIICHUsernameLoginFixture(lookup: .init(result: .failure(.uncertain)))
        try await fixture.configure()
        #expect(await fixture.login(username: "ivan").usernameLoginFailure != nil)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)

        fixture.lookup.result = .success(CHIICHUsernameLookupFixture.response)
        _ = try await fixture.login(username: "ivan").get()
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test
    func lookupParticipatesInTheExistingAuthenticationExclusion() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        let gate = CHIICHUsernameLookupGate()
        fixture.lookup.gate = gate
        try await fixture.configure()
        let homeserver = fixture.service.homeserver.value
        let operation = Task { await fixture.login(username: "ivan") }
        await gate.waitUntilEntered()
        let callback = try #require(SSOCallback(scheme: "one.chiich.app"))
        #expect(await fixture.service.beginSSOLogin(provider: .apple, callback: callback).usernameLoginFailure != nil)
        #expect(await fixture.login(username: "different").usernameLoginFailure != nil)
        #expect(await fixture.service.configure(for: "company.com", flow: .login).usernameLoginFailure != nil)
        fixture.service.reset()
        #expect(fixture.service.homeserver.value == homeserver)
        #expect(fixture.lookup.requests.count == 1)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)

        await gate.release()
        _ = try await operation.value.get()
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test
    func cancellationDiscardsALateLookupWithoutSendingAPassword() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        let gate = CHIICHUsernameLookupGate()
        fixture.lookup.gate = gate
        try await fixture.configure()
        let operation = Task { await fixture.login(username: "ivan") }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        #expect(await operation.value.usernameLoginFailure != nil)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)

        fixture.lookup.gate = nil
        _ = try await fixture.login(username: "ivan").get()
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test(arguments: ["ivan", "@existing=40email:chat.chiich.one"])
    func cancellationDuringSDKExchangeLogsOutBeforeSessionCommit(_ username: String) async throws {
        let fixture = CHIICHUsernameLoginFixture()
        let gate = CHIICHUsernameLookupGate()
        try await fixture.configure()
        fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { _, _, _, _ in
            await gate.suspend()
            fixture.client.userIdReturnValue = CHIICHUsernameLookupFixture.userID
        }
        let operation = Task { await fixture.login(username: username) }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        #expect(await operation.value.usernameLoginFailure != nil)
        #expect(fixture.client.logoutCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test
    func cancellationDuringVerificationLogsOutBeforeSessionCommit() async throws {
        let configuration = ClientFactoryMock.Configuration()
        let client = try #require(configuration.homeserverClients["matrix.org"])
        let encryption = EncryptionSDKMock()
        client.encryptionReturnValue = encryption
        let manager = UserSessionManagerMock(.init())
        let classic = ClassicAppManagerMock(.init(accounts: [.mockAlice], availableSecrets: .complete,
                                                  secretsBundle: SecretsBundleWithUserIdSDKMock()))
        let service = AuthenticationService(userSessionManager: manager,
                                            encryptionKeyProvider: MockEncryptionKeyProvider(),
                                            classicAppManager: classic,
                                            clientFactory: ClientFactoryMock(configuration),
                                            appSettings: .volatile(),
                                            appHooks: AppHooks())
        await service.setupClassicAppAccountState()
        try #require(service.classicAppAccount?.state.availableSecrets == .complete)
        try await service.configure(for: "matrix.org", flow: .login).get()
        let gate = CHIICHUsernameLookupGate()
        encryption.importSecretsBundleSecretsBundleClosure = { _ in await gate.suspend() }
        let operation = Task { await service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil) }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        #expect(await operation.value.usernameLoginFailure != nil)
        #expect(client.logoutCallsCount == 1)
        #expect(manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test
    func cancellationAfterNativeCommitStartsStillDeliversThePersistedSession() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        try await fixture.configure()
        let gate = CHIICHUsernameLookupGate()
        let session = UserSessionMock(.init())
        fixture.manager.userSessionForSessionDirectoriesPassphraseClosure = { _, _, _ in
            await gate.suspend()
            return .success(session)
        }
        let operation = Task { await fixture.login(username: "ivan") }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        _ = try await operation.value.get()
        #expect(fixture.client.logoutCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test
    func aDifferentAuthenticatedAccountCannotReplaceTheResolvedOwner() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        try await fixture.configure()
        fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { _, _, _, _ in
            fixture.client.userIdReturnValue = "@different:chat.chiich.one"
        }
        #expect(await fixture.login(username: "ivan").usernameLoginFailure == .invalidCredentials)
        #expect(fixture.client.logoutCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test
    func unsupportedPasswordCapabilityNeverStartsTheLookup() async throws {
        let fixture = CHIICHUsernameLoginFixture()
        let details = try #require(fixture.client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock)
        details.supportsPasswordLoginReturnValue = false
        try await fixture.configure()
        #expect(await fixture.login(username: "ivan").usernameLoginFailure != nil)
        #expect(fixture.lookup.requests.isEmpty)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
    }
}

@MainActor
private struct CHIICHUsernameLoginFixture {
    static let password = "synthetic-password-only"
    let client: ClientSDKMock
    let manager: UserSessionManagerMock
    let service: AuthenticationService
    let lookup: CHIICHUsernameLookupFixture

    init(lookup: CHIICHUsernameLookupFixture = .init()) {
        self.lookup = lookup
        var clientConfiguration = ClientSDKMock.Configuration()
        clientConfiguration.serverName = "chat.chiich.one"
        clientConfiguration.homeserverURL = "https://matrix.chiich.one"
        clientConfiguration.oAuthLoginURL = nil
        clientConfiguration.validCredentials = (CHIICHUsernameLookupFixture.userID, Self.password)
        client = ClientSDKMock(clientConfiguration)
        let details = client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock
        details?.supportsSsoLoginReturnValue = true
        var factoryConfiguration = ClientFactoryMock.Configuration()
        factoryConfiguration.homeserverClients["chat.chiich.one"] = client
        manager = UserSessionManagerMock(.init())
        service = AuthenticationService(userSessionManager: manager,
                                        encryptionKeyProvider: MockEncryptionKeyProvider(),
                                        classicAppManager: nil,
                                        clientFactory: ClientFactoryMock(factoryConfiguration),
                                        passwordLoginResolver: lookup.resolver,
                                        appSettings: .volatile(),
                                        appHooks: AppHooks())
    }

    func configure() async throws {
        try await service.configure(for: "chat.chiich.one", flow: .login).get()
    }

    func login(username: String) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        await service.login(username: username, password: Self.password, initialDeviceName: "Synthetic iPhone", deviceID: "EXISTINGDEVICE")
    }
}

private extension Result {
    var usernameLoginFailure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
