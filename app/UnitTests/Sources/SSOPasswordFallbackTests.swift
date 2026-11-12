//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Combine
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SSOPasswordFallbackTests {
    @Test(arguments: [true, false])
    func fallbackRequiresDiscoveredPasswordCapability(supportsPassword: Bool) async throws {
        let fixture = try PasswordFallbackFixture(supportsPassword: supportsPassword)
        let viewModel = try await fixture.loginViewModel()
        let context = viewModel.context

        #expect(fixture.service.homeserver.value.loginMode == .sso)
        #expect(fixture.service.homeserver.value.supportsPasswordLogin == supportsPassword)
        #expect(context.viewState.canShowPasswordFallback == supportsPassword)
        #expect(!context.viewState.isPasswordLoginVisible)
        context.username = "alice"
        context.password = "12345678" // Synthetic fixture only.
        #expect(!context.viewState.canSubmit)

        context.send(viewAction: .togglePasswordLogin)
        #expect(context.viewState.isPasswordLoginVisible == supportsPassword)
        #expect(context.viewState.canSubmit == supportsPassword)
        #expect(context.viewState.loginMode == .sso)
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
    }

    @Test
    func registrationNeverExposesExistingAccountPasswordFallback() async throws {
        let fixture = try PasswordFallbackFixture()
        let viewModel = try await fixture.loginViewModel(flow: .register)
        let context = viewModel.context
        context.username = "alice"
        context.password = "12345678"

        context.send(viewAction: .togglePasswordLogin)
        context.send(viewAction: .next)

        #expect(context.viewState.loginMode == .sso)
        #expect(!context.viewState.canShowPasswordFallback)
        #expect(!context.viewState.isPasswordLoginVisible)
        #expect(!context.viewState.canSubmit)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test
    func collapsingFallbackDiscardsPasswordAndRetainsSSO() async throws {
        let fixture = try PasswordFallbackFixture()
        let viewModel = try await fixture.loginViewModel()
        let context = viewModel.context
        context.send(viewAction: .togglePasswordLogin)
        context.username = "alice"
        context.password = "12345678"
        context.send(viewAction: .togglePasswordLogin)

        #expect(context.password.isEmpty)
        #expect(context.username == "alice")
        #expect(!context.viewState.canSubmit)
        #expect(context.viewState.canShowPasswordFallback)
        #expect(context.viewState.loginMode == .sso)
    }

    @Test(arguments: ["@alice:company.com", "@alice:example.com.evil.invalid"])
    func foreignMatrixIDCannotDiscoverServerOrSendPassword(username: String) async throws {
        let fixture = try PasswordFallbackFixture()
        let viewModel = try await fixture.loginViewModel()
        let context = viewModel.context
        let configuredHomeserver = fixture.service.homeserver.value
        let clientBuilds = fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount
        context.send(viewAction: .togglePasswordLogin)
        context.username = username
        context.password = "12345678"

        context.send(viewAction: .parseUsername)
        #expect(!context.viewState.isLoading)
        context.send(viewAction: .next)

        #expect(context.alertInfo?.id == .credentialsAlert)
        #expect(fixture.service.homeserver.value == configuredHomeserver)
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == clientBuilds)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test(arguments: ["alice", "@alice:example.com"])
    func fallbackUsesNativePasswordLoginWithoutServerDiscovery(username: String) async throws {
        let fixture = try PasswordFallbackFixture()
        // Accept both normal username spellings in this synthetic SDK fixture.
        fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { _, _, _, _ in }
        let viewModel = try await fixture.loginViewModel()
        let context = viewModel.context
        let clientBuilds = fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount
        context.send(viewAction: .togglePasswordLogin)
        context.username = username
        context.password = "12345678"
        context.send(viewAction: .parseUsername)
        let signedIn = deferFulfillment(viewModel.actions) {
            if case .signedIn = $0 { return true }
            return false
        }

        context.send(viewAction: .next)
        #expect(context.viewState.isLoading)
        try await signedIn.fulfill()

        let arguments = try #require(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdReceivedArguments)
        #expect(arguments.username == username)
        #expect(arguments.password == "12345678")
        #expect(arguments.deviceId == nil)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == clientBuilds)
    }

    @Test
    func passwordSubmissionCannotBeRepeatedOrCollapsedWhilePending() async throws {
        let fixture = try PasswordFallbackFixture()
        let gate = PasswordFallbackGate()
        fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { _, _, _, _ in await gate.suspend() }
        let viewModel = try await fixture.loginViewModel()
        let context = viewModel.context
        context.send(viewAction: .togglePasswordLogin)
        context.username = "alice"
        context.password = "12345678"
        let signedIn = deferFulfillment(viewModel.actions) {
            if case .signedIn = $0 { return true }
            return false
        }

        context.send(viewAction: .next)
        await gate.waitUntilEntered()
        context.send(viewAction: .next)
        context.send(viewAction: .togglePasswordLogin)
        #expect(context.viewState.isLoading)
        #expect(!context.viewState.canSubmit)
        #expect(context.viewState.isPasswordLoginExpanded)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        await gate.release()
        try await signedIn.fulfill()
    }

    @Test
    func passwordCapabilityIsAlsoEnforcedAtServiceBoundary() async throws {
        let fixture = try PasswordFallbackFixture(supportsPassword: false)
        try await fixture.service.configure(for: "example.com", flow: .login).get()
        let result = await fixture.service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil)

        #expect(result.passwordFallbackFailure != nil)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }

    @Test(arguments: [false, true])
    func passwordExchangeAndCommitExcludeOtherAuthentication(duringCommit: Bool) async throws {
        let fixture = try PasswordFallbackFixture()
        try await fixture.service.configure(for: "example.com", flow: .login).get()
        let configuredHomeserver = fixture.service.homeserver.value
        let gate = PasswordFallbackGate()
        if duringCommit {
            let session = UserSessionMock(.init())
            fixture.manager.userSessionForSessionDirectoriesPassphraseClosure = { _, _, _ in
                await gate.suspend()
                return .success(session)
            }
        } else {
            fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { _, _, _, _ in await gate.suspend() }
        }
        let operation = Task {
            await fixture.service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil)
        }
        await gate.waitUntilEntered()
        let callback = try #require(SSOCallback(scheme: "one.chiich.app"))
        let sso = await fixture.service.beginSSOLogin(provider: .apple, callback: callback)
        let duplicate = await fixture.service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil)
        let reconfigure = await fixture.service.configure(for: "company.com", flow: .login)
        fixture.service.reset()

        #expect(sso.passwordFallbackFailure != nil)
        #expect(duplicate.passwordFallbackFailure != nil)
        #expect(reconfigure.passwordFallbackFailure != nil)
        #expect(fixture.service.homeserver.value == configuredHomeserver)
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        await gate.release()
        _ = try await operation.value.get()
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
        try await fixture.service.configure(for: "example.com", flow: .login).get()
    }

    @Test
    func activeSSOExcludesPasswordUntilCancelled() async throws {
        let fixture = try PasswordFallbackFixture()
        try await fixture.service.configure(for: "example.com", flow: .login).get()
        let callback = try #require(SSOCallback(scheme: "one.chiich.app"))
        let request = try await fixture.service.beginSSOLogin(provider: .google, callback: callback).get()
        let password = await fixture.service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil)
        let reconfigure = await fixture.service.configure(for: "company.com", flow: .login)

        #expect(password.passwordFallbackFailure != nil)
        #expect(reconfigure.passwordFallbackFailure != nil)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.service.cancelSSOLogin(requestID: request.id))
        _ = try await fixture.service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil).get()
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 1)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test
    func failedPasswordAttemptReleasesAuthenticationLockForRetry() async throws {
        let fixture = try PasswordFallbackFixture()
        try await fixture.service.configure(for: "example.com", flow: .login).get()
        let result = await fixture.service.login(username: "alice", password: "wrong-synthetic-password", initialDeviceName: nil, deviceID: nil)
        #expect(result.passwordFallbackFailure != nil)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)

        _ = try await fixture.service.login(username: "alice", password: "12345678", initialDeviceName: nil, deviceID: nil).get()
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 2)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }

    @Test(arguments: [true, false])
    func softLogoutFallbackKeepsAccountAndBlocksDuplicateActions(supportsPassword: Bool) {
        let credentials = SoftLogoutScreenCredentials(userID: "@alice:example.com",
                                                      homeserverName: "example.com",
                                                      userDisplayName: "Alice",
                                                      deviceID: "EXISTINGDEVICE")
        let homeserver = LoginHomeserver(accountProvider: .generic("example.com"),
                                         loginMode: .sso,
                                         supportsPasswordLogin: supportsPassword)
        let viewModel = SoftLogoutScreenViewModel(credentials: credentials,
                                                  homeserver: homeserver,
                                                  keyBackupNeeded: true,
                                                  password: "12345678")
        let context = viewModel.context
        var actions = [SoftLogoutScreenViewModelAction]()
        let subscription = viewModel.actions.sink { actions.append($0) }
        defer { subscription.cancel() }

        context.send(viewAction: .login)
        #expect(actions.isEmpty)
        context.send(viewAction: .togglePasswordLogin)
        #expect(context.viewState.canSubmit == supportsPassword)
        context.send(viewAction: .login)
        #expect(actions.count == (supportsPassword ? 1 : 0))
        #expect(context.isAuthenticating == supportsPassword)
        if supportsPassword {
            if case .login(let password) = actions[0] {
                #expect(password == "12345678")
                #expect(actions[0].description == "login")
            } else {
                Issue.record("Password fallback emitted a different authentication action.")
            }
            context.send(viewAction: .login)
            context.send(viewAction: .continueWithSSO(.apple))
            context.send(viewAction: .clearAllData)
            context.send(viewAction: .togglePasswordLogin)
            #expect(actions.count == 1)
            #expect(context.viewState.isPasswordLoginExpanded)
        }
        #expect(context.viewState.credentials.userID == credentials.userID)
        #expect(context.viewState.credentials.deviceID == credentials.deviceID)
        #expect(context.viewState.showRecoverEncryptionKeysMessage)
    }

    @Test
    func softLogoutPasswordUsesExplicitAccountAndExistingDevice() async throws {
        let fixture = try PasswordFallbackFixture()
        try await fixture.service.configure(for: "example.com", flow: .login).get()
        fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdClosure = { _, _, _, _ in }
        _ = try await fixture.service.login(username: "@alice:example.com",
                                            password: "12345678",
                                            initialDeviceName: "Synthetic iPhone",
                                            deviceID: "EXISTINGDEVICE").get()

        let arguments = try #require(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdReceivedArguments)
        #expect(arguments.username == "@alice:example.com")
        #expect(arguments.deviceId == "EXISTINGDEVICE")
        #expect(arguments.initialDeviceName == "Synthetic iPhone")
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 1)
    }
}

@MainActor
private struct PasswordFallbackFixture {
    let settings: AppSettings
    let client: ClientSDKMock
    let factory: ClientFactoryMock
    let manager: UserSessionManagerMock
    let service: AuthenticationService

    init(supportsPassword: Bool = true) throws {
        let configuration = ClientFactoryMock.Configuration()
        client = try #require(configuration.homeserverClients["example.com"])
        let details = try #require(client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock)
        details.supportsSsoLoginReturnValue = true
        details.supportsPasswordLoginReturnValue = supportsPassword
        client.userIdReturnValue = "@alice:example.com"
        let handler = SsoHandlerSDKMock()
        handler.urlReturnValue = "https://matrix.example.com/_matrix/client/v3/login/sso/redirect/oidc-google"
        client.startSsoLoginRedirectUrlIdpIdReturnValue = handler
        factory = ClientFactoryMock(configuration)
        manager = UserSessionManagerMock(.init())
        settings = .volatile()
        settings.configurePasswordFallbackTests(allowOtherAccountProviders: false)
        service = AuthenticationService(userSessionManager: manager,
                                        encryptionKeyProvider: MockEncryptionKeyProvider(),
                                        classicAppManager: nil,
                                        clientFactory: factory,
                                        appSettings: settings,
                                        appHooks: AppHooks())
    }

    func loginViewModel(flow: AuthenticationFlow = .login) async throws -> LoginScreenViewModel {
        try await service.configure(for: "example.com", flow: flow).get()
        return LoginScreenViewModel(authenticationService: service,
                                    loginHint: nil,
                                    userIndicatorController: UserIndicatorControllerMock(),
                                    appSettings: settings)
    }
}

// Shared with the preserved upstream view-model tests, which explicitly opt in
// to their synthetic multi-server fixtures instead of changing CHIICH defaults.
extension AppSettings {
    func configurePasswordFallbackTests(allowOtherAccountProviders: Bool) {
        override(accountProviders: [.managed(serverName: "example.com", baseURL: "https://matrix.example.com")],
                 allowOtherAccountProviders: allowOtherAccountProviders,
                 hideBrandChrome: hideBrandChrome,
                 pushGatewayBaseURL: pushGatewayBaseURL,
                 oAuthRedirectURL: oAuthRedirectURL,
                 oAuthClientURIPath: oAuthClientURIPath,
                 websiteURL: websiteURL,
                 logoURL: logoURL,
                 copyrightURL: copyrightURL,
                 acceptableUseURL: acceptableUseURL,
                 privacyURL: privacyURL,
                 encryptionURL: encryptionURL,
                 deviceVerificationURL: deviceVerificationURL,
                 chatBackupDetailsURL: chatBackupDetailsURL,
                 identityPinningViolationDetailsURL: identityPinningViolationDetailsURL,
                 historySharingDetailsURL: historySharingDetailsURL,
                 elementWebHosts: elementWebHosts,
                 accountProvisioningHost: accountProvisioningHost,
                 bugReportApplicationID: bugReportApplicationID,
                 analyticsTermsURL: analyticsTermsURL,
                 mapTilerConfiguration: mapTilerConfiguration.publisher.value)
    }
}

private extension Result {
    var passwordFallbackFailure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private actor PasswordFallbackGate {
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
