//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
//

@testable import ElementX
import MatrixRustSDKMocks
import Testing

@MainActor
struct CHIICHManagedAccountProviderTests {
    @Test
    func welcomeLoginUsesAPIHostAndKeepsAccountIdentity() async throws {
        // Use the shipping settings and the real welcome/service path. Only the
        // reachable API host exists in this fixture; identity-domain discovery fails.
        let settings = AppSettings.volatile()
        let client = ClientSDKMock(.init(serverName: "chat.chiich.one",
                                         homeserverURL: "https://matrix.chiich.one",
                                         oAuthLoginURL: nil,
                                         supportsPasswordLogin: true))
        let details = try #require(client.homeserverLoginDetailsReturnValue as? HomeserverLoginDetailsSDKMock)
        details.supportsSsoLoginReturnValue = true
        let factory = ClientFactoryMock(.init(homeserverClients: ["matrix.chiich.one": client]))
        let service = AuthenticationService(userSessionManager: UserSessionManagerMock(.init()),
                                            encryptionKeyProvider: MockEncryptionKeyProvider(),
                                            classicAppManager: nil,
                                            clientFactory: factory,
                                            appSettings: settings,
                                            appHooks: AppHooks())
        let viewModel = AuthenticationStartScreenViewModel(authenticationService: service,
                                                          provisioningParameters: nil,
                                                          isBugReportServiceEnabled: false,
                                                          appMediator: AppMediatorMock(),
                                                          appSettings: settings,
                                                          mediaProvider: nil,
                                                          userIndicatorController: UserIndicatorControllerMock())
        let configured = deferFulfillment(viewModel.actions) { action in
            if case .loginDirectlyWithPassword = action { return true }
            return false
        }

        viewModel.context.send(viewAction: .login)
        try await configured.fulfill()

        #expect(factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksCallsCount == 1)
        #expect(factory.makeAuthenticationClientServerNameOrBaseURLSessionDirectoriesPassphraseClientSessionDelegateAppSettingsAppHooksReceivedArguments?.serverNameOrBaseURL == "matrix.chiich.one")
        #expect(service.homeserver.value.loginMode == .sso)
        #expect(viewModel.context.alertInfo == nil)
        // Choosing the reachable API must not change immutable Matrix user IDs.
        #expect(settings.accountProviders.contains(serverName: "chat.chiich.one", orBaseURL: nil))
        #expect(!settings.accountProviders.contains(serverName: "matrix.chiich.one", orBaseURL: nil))
    }
}
