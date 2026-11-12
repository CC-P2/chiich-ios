//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CHIICHLoginEntryTests {
    @Test
    func managedProviderOpensLoginAsTheRootScreen() throws {
        let fixture = try LoginEntryFixture()
        let root = NavigationRootCoordinator()
        let coordinator = AuthenticationFlowCoordinator(authenticationService: fixture.service,
                                                        bugReportService: BugReportServiceMock(.init()),
                                                        navigationRootCoordinator: root,
                                                        appMediator: AppMediatorMock(.init()),
                                                        appSettings: fixture.settings,
                                                        appHooks: AppHooks(),
                                                        userIndicatorController: UserIndicatorControllerMock())
        coordinator.start()
        
        let stack = try #require(root.rootCoordinator as? NavigationStackCoordinator)
        let login = try #require(stack.rootCoordinator as? LoginScreenCoordinator)
        #expect(stack.stackCoordinators.isEmpty)
        #expect(!(stack.rootCoordinator is AuthenticationStartScreenCoordinator))
        login.stop()
    }
    
    @Test
    func discoveryUsesTheAPIHostAndDoesNotStartAuthentication() async throws {
        let fixture = try LoginEntryFixture()
        let viewModel = fixture.viewModel()
        let context = viewModel.context
        var actions: [LoginScreenViewModelAction] = []
        let subscription = viewModel.actions.sink { actions.append($0) }
        let configured = deferFulfillment(context.observe(\.viewState.configurationState)) { $0 == .ready }
        
        #expect(context.viewState.configurationState == .loading)
        #expect(!context.viewState.canShowPasswordFallback)
        context.send(viewAction: .configureAccountProvider)
        try await configured.fulfill()
        
        let arguments = try #require(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksReceivedArguments)
        #expect(arguments.serverNameOrBaseURL == "matrix.chiich.one")
        #expect(fixture.settings.accountProviders.contains(serverName: "chat.chiich.one", orBaseURL: nil))
        #expect(context.viewState.loginMode == .sso)
        #expect(context.viewState.canShowPasswordFallback)
        #expect(!context.viewState.isPasswordLoginVisible)
        #expect(!context.viewState.isLoading)
        withExtendedLifetime(subscription) { #expect(actions.isEmpty) }
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }
    
    @Test
    func discoveryFailureCanBeRetriedOnTheSameScreen() async throws {
        let fixture = try LoginEntryFixture()
        fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksClosure = { _, _, _, _, _, _ in
            throw ClientBuildError.ServerUnreachable(message: "Synthetic offline server")
        }
        let viewModel = fixture.viewModel()
        let context = viewModel.context
        let failed = deferFulfillment(context.observe(\.viewState.configurationState)) {
            if case .failed = $0 {
                return true
            }
            return false
        }
        context.send(viewAction: .configureAccountProvider)
        try await failed.fulfill()
        #expect(!context.viewState.isLoading)
        #expect(!context.viewState.canShowPasswordFallback)
        #expect(!context.viewState.canSubmit)
        #expect(context.alertInfo == nil)
        
        let client = fixture.client
        fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksClosure = { _, _, _, _, _, _ in client }
        let ready = deferFulfillment(context.observe(\.viewState.configurationState)) { $0 == .ready }
        context.send(viewAction: .configureAccountProvider)
        try await ready.fulfill()
        #expect(context.viewState.loginMode == .sso)
        #expect(context.viewState.canShowPasswordFallback)
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == 2)
    }
    
    @Test
    func repeatedTapsCannotOverlapDiscoveryOrAuthenticate() async throws {
        let fixture = try LoginEntryFixture()
        let gate = LoginEntryGate()
        let client = fixture.client
        fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksClosure = { _, _, _, _, _, _ in
            await gate.suspend()
            return client
        }
        let viewModel = fixture.viewModel()
        let context = viewModel.context
        context.username = "alice"
        context.password = "synthetic-password"
        let ready = deferFulfillment(context.observe(\.viewState.configurationState)) { $0 == .ready }
        context.send(viewAction: .configureAccountProvider)
        await gate.waitUntilEntered()
        context.send(viewAction: .configureAccountProvider)
        context.send(viewAction: .continueWithSSO(.apple))
        context.send(viewAction: .togglePasswordLogin)
        context.send(viewAction: .next)
        
        #expect(context.viewState.isLoading)
        #expect(!context.viewState.canSubmit)
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == 1)
        #expect(fixture.client.startSsoLoginRedirectUrlIdpIdCallsCount == 0)
        #expect(fixture.client.loginUsernamePasswordInitialDeviceNameDeviceIdCallsCount == 0)
        await gate.release()
        try await ready.fulfill()
    }
    
    @Test
    func cancelledDiscoveryCannotExposeAuthenticationFromItsLateResult() async throws {
        let fixture = try LoginEntryFixture()
        let gate = LoginEntryGate()
        let client = fixture.client
        fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksClosure = { _, _, _, _, _, _ in
            await gate.suspend()
            return client
        }
        let viewModel = fixture.viewModel()
        let context = viewModel.context
        let returned = deferFulfillment(fixture.service.homeserver) { $0.loginMode == .sso }
        context.send(viewAction: .configureAccountProvider)
        await gate.waitUntilEntered()
        viewModel.cancelInitialConfiguration()
        #expect(context.viewState.configurationState == .loading)
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == 1)
        await gate.release()
        try await returned.fulfill()
        
        if case .failed = context.viewState.configurationState {
            #expect(!context.viewState.canShowPasswordFallback)
            #expect(!context.viewState.canSubmit)
        } else {
            Issue.record("A cancelled discovery must not expose provider or password actions.")
        }
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }
    
    @Test
    func coordinatorReappearanceQueuesOneDiscoveryAfterCancellation() async throws {
        let fixture = try LoginEntryFixture()
        let gate = LoginEntryGate()
        let client = fixture.client
        fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksClosure = { _, _, _, _, _, _ in
            await gate.suspend()
            return client
        }
        let coordinator = LoginScreenCoordinator(parameters: .init(authenticationService: fixture.service,
                                                                   loginHint: nil,
                                                                   userIndicatorController: UserIndicatorControllerMock(),
                                                                   appSettings: fixture.settings,
                                                                   initialAccountProvider: fixture.settings.accountProviders.first))
        coordinator.start()
        await gate.waitUntilEntered()
        coordinator.stop()
        coordinator.start()
        coordinator.start()
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == 1)
        
        let (retried, continuation) = AsyncStream<Bool>.makeStream()
        fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksClosure = { _, _, _, _, _, _ in
            continuation.yield(true)
            return client
        }
        let restarted = deferFulfillment(retried) { $0 }
        await gate.release()
        try await restarted.fulfill()
        #expect(fixture.factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == 2)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
        coordinator.stop()
        continuation.finish()
    }
    
    @Test
    func directEntryDoesNotAutomaticallyOpenANewOAuthFlow() async throws {
        let fixture = try LoginEntryFixture()
        let details = try #require(fixture.client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock)
        details.supportsOauthLoginReturnValue = true
        let viewModel = fixture.viewModel()
        let context = viewModel.context
        let unsupported = deferFulfillment(context.observe(\.viewState.configurationState)) {
            if case .failed = $0 {
                return true
            }
            return false
        }
        context.send(viewAction: .configureAccountProvider)
        try await unsupported.fulfill()
        
        #expect(!context.viewState.canShowPasswordFallback)
        #expect(!context.viewState.canSubmit)
        #expect(!context.viewState.isLoading)
        #expect(fixture.client.urlForOauthOauthConfigurationPromptLoginHintDeviceIdAdditionalScopesCallsCount == 0)
        #expect(fixture.manager.userSessionForSessionDirectoriesPassphraseCallsCount == 0)
    }
}

private struct LoginEntryFixture {
    let settings = AppSettings.volatile()
    let client: ClientSDKMock
    let factory: ClientFactoryMock
    let manager = UserSessionManagerMock(.init())
    let service: AuthenticationService
    
    init() throws {
        client = ClientSDKMock(.init(serverName: "chat.chiich.one",
                                     homeserverURL: "https://matrix.chiich.one",
                                     oAuthLoginURL: nil,
                                     supportsOAuthCreatePrompt: false,
                                     supportsPasswordLogin: true))
        let details = try #require(client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock)
        details.supportsSsoLoginReturnValue = true
        factory = ClientFactoryMock(.init(homeserverClients: ["matrix.chiich.one": client]))
        service = AuthenticationService(userSessionManager: manager,
                                        encryptionKeyProvider: MockEncryptionKeyProvider(),
                                        classicAppManager: nil,
                                        clientFactory: factory,
                                        appSettings: settings,
                                        appHooks: AppHooks())
    }
    
    func viewModel() -> LoginScreenViewModel {
        LoginScreenViewModel(authenticationService: service,
                             loginHint: nil,
                             userIndicatorController: UserIndicatorControllerMock(),
                             appSettings: settings,
                             initialAccountProvider: settings.accountProviders.first)
    }
}

private actor LoginEntryGate {
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
