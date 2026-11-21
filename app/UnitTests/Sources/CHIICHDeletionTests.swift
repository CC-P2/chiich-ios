// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

final class CHIICHDeletionTests {
    @Test
    func ownedSSOAccountAlwaysHasDeletionAndExternalAvailabilityIsPreserved() {
        for (owned, native, visible) in [(true, false, true), (false, true, true), (false, false, false)] {
            let proxy = ClientProxyMock(.init(supportsCHIICHDeletion: owned))
            proxy.canDeactivateAccount = native
            let screen = SettingsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: proxy, userSettings: .mock())),
                                                 isBugReportServiceEnabled: false, isInSecondaryWindow: false,
                                                 userIndicatorController: UserIndicatorControllerMock())
            #expect(screen.state.showAccountDeactivation == visible)
        }
    }

    @Test
    func requestHasOneOwnedEndpointAndAlwaysErases() throws {
        let context = try Self.context()
        let request = try CHIICHDeletionRequest(authentication: nil).urlRequest(context: context)
        #expect(request.url?.absoluteString == "https://matrix.chiich.one/_matrix/client/v3/account/deactivate")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Bool])
        #expect(body == ["erase": true])
        let credential = CHIICHPasswordAuth.password(.init(identifier: "@other:chat.chiich.one", password: "test-only", session: "uia-test-only"))
        #expect(throws: CHIICHPasswordError.currentPasswordRequired) {
            try CHIICHDeletionRequest(authentication: credential).urlRequest(context: context)
        }
        #expect(!String(describing: CHIICHDeletionRequest(authentication: credential)).contains("test-only"))
    }

    @Test
    func onlyValidDeactivationResponseConfirmsClosure() throws {
        for result in ["success", "no-support"] {
            #expect(CHIICHDeletionResponse.classify(data: try Self.json(["id_server_unbind_result": result]), statusCode: 200) == .success(.success))
        }
        let invalidBodies: [[String: Any]] = [[:], ["id_server_unbind_result": "unexpected"], ["id_server_unbind_result": "success", "errcode": "M_FORBIDDEN"]]
        for body in invalidBodies {
            #expect(CHIICHDeletionResponse.classify(data: try Self.json(body), statusCode: 200) == .failure(.outcomeUnknown))
        }
        #expect(CHIICHDeletionResponse.classify(data: Data(repeating: 32, count: 64_001), statusCode: 200) == .failure(.outcomeUnknown))
        #expect(CHIICHDeletionResponse.classify(data: try Self.json(["id_server_unbind_result": "success"]), statusCode: 302) == .failure(.outcomeUnknown))
        #expect(CHIICHDeletionResponse.classify(data: try Self.json(["errcode": "M_UNKNOWN_TOKEN"]), statusCode: 401) == .failure(.matrixUnknownToken(softLogout: false)))
    }

    @Test
    func noRequestWithoutConfirmationAndOnlyOneInitialSubmission() async throws {
        let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.sso"])))])
        let service = try fixture.service()
        #expect(await service.begin(confirmed: false) == .failure(.cancelled))
        #expect(fixture.requests.isEmpty)
        _ = await service.begin(confirmed: true)
        #expect(await service.begin(confirmed: true) == .failure(.cancelled))
        #expect(fixture.requests.count == 1)
    }

    @Test
    func ssoDoesNotRequirePasswordOrTreatBrowserCloseAsSuccess() async throws {
        let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.sso"]))), .success(.success)])
        let service = try fixture.service()
        _ = await service.begin(confirmed: true)
        #expect(fixture.requests[0].authentication == nil)
        let browser = try service.ssoPresentation().get()
        #expect(browser.url.path == "/_matrix/client/v3/auth/m.login.sso/fallback/web")
        #expect(!service.browserReturned(nonce: UUID()))
        #expect(await service.confirmSSO(nonce: browser.id) == .failure(.expiredChallenge))
        #expect(service.browserReturned(nonce: browser.id))
        #expect(fixture.requests.count == 1)
        #expect(fixture.confirmations == 0)
        #expect(await service.confirmSSO(nonce: browser.id) == .success(.success))
        guard case .session("uia-test-only")? = fixture.requests[1].authentication else {
            Issue.record("Must submit the same UIA session, never a new login token.")
            return
        }
        #expect(fixture.confirmations == 1)
    }

    @Test
    func explicitFinishInBrowserChecksTheSameSessionEvenIfAppleIsStillLoading() async throws {
        let challenge = Self.challenge(["m.login.sso"])
        let fixture = Fixture([.success(.challenge(challenge)), .success(.challenge(challenge)), .success(.success)])
        let screen = try CHIICHDeletionScreenViewModel(service: fixture.service())
        screen.start()
        screen.process(viewAction: .confirmDeletion)
        try await Self.waitUntil { screen.state.mode == .authentication }
        screen.process(viewAction: .openSSO)
        let nonce = try #require(screen.state.bindings.browser?.id)
        #expect(fixture.requests.count == 1)
        screen.process(viewAction: .confirmSSO) // No Safari delegate/dismissal callback.
        screen.process(viewAction: .browserSheetDismissed)
        try await Self.waitUntil { !screen.state.isWorking }
        #expect(screen.state.returnedBrowserNonce == nonce)
        #expect(fixture.confirmations == 0)
        screen.process(viewAction: .confirmSSO)
        try await Self.waitUntil { screen.state.mode == .success }
        #expect(fixture.requests.dropFirst().map { $0.authentication?.sessionID } == [challenge.session, challenge.session])
        #expect(fixture.confirmations == 1)
    }

    @Test
    func reopeningSettingsResumesSameSSOWithoutAnotherLoginOrAutomaticDeletion() async throws {
        let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.sso"]))), .success(.success)])
        let recovery = CHIICHDeletionRecovery()
        let screen = try CHIICHDeletionScreenViewModel(service: fixture.service(recovery: recovery))
        screen.start()
        screen.process(viewAction: .confirmDeletion)
        try await Self.waitUntil { screen.state.mode == .authentication }
        screen.process(viewAction: .openSSO)
        let nonce = try #require(screen.state.bindings.browser?.id)
        screen.stop() // Navigation has returned to Chats before Safari reported dismissal.
        let resumed = CHIICHDeletionScreenViewModel(service: try #require(recovery.take()))
        resumed.start()
        #expect(resumed.state.mode == .authentication)
        #expect(resumed.state.returnedBrowserNonce == nonce)
        #expect(fixture.requests.count == 1)
        resumed.process(viewAction: .confirmSSO)
        try await Self.waitUntil { resumed.state.mode == .success }
        #expect(fixture.requests.count == 2)
        #expect(fixture.confirmations == 1)
    }

    @Test
    func cancellingOrChangingSessionDiscardsSuspendedDeletion() async throws {
        for cancel in [true, false] {
            let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.sso"])))])
            let recovery = CHIICHDeletionRecovery()
            let screen = try CHIICHDeletionScreenViewModel(service: fixture.service(recovery: recovery))
            screen.start()
            screen.process(viewAction: .confirmDeletion)
            try await Self.waitUntil { screen.state.mode == .authentication }
            screen.process(viewAction: .openSSO)
            if cancel { screen.process(viewAction: .close) } else { screen.stop(); fixture.current = false }
            #expect(recovery.take() == nil)
            #expect(fixture.requests.count == 1)
        }
    }

    @Test
    func passwordAndSSOSequentialStagesRemainBoundToOriginalSession() async throws {
        let first = Self.challenge(["m.login.password", "m.login.sso"])
        let second = Self.challenge(["m.login.password", "m.login.sso"], completed: ["m.login.password"])
        let fixture = Fixture([.success(.challenge(first)), .success(.challenge(second)), .success(.success)])
        let service = try fixture.service()
        _ = await service.begin(confirmed: true)
        #expect(service.ssoPresentation() == .failure(.expiredChallenge))
        #expect(await service.submitPassword("") == .failure(.currentPasswordRequired))
        _ = await service.submitPassword(" old-password-test-only ")
        guard case .password(let details)? = fixture.requests[1].authentication else { Issue.record("Missing UIA password"); return }
        #expect(details.password == " old-password-test-only ")
        #expect(details.identifier == service.context.accountID)
        let browser = try service.ssoPresentation().get()
        #expect(service.browserReturned(nonce: browser.id))
        #expect(await service.confirmSSO(nonce: browser.id) == .success(.success))
    }

    @Test
    func changedOrUnsupportedUIAIsNeverBypassed() async throws {
        let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.password"]))),
                               .success(.challenge(Self.challenge(["m.login.password"], session: "changed-test-only")))])
        let service = try fixture.service()
        _ = await service.begin(confirmed: true)
        #expect(await service.submitPassword("test-only") == .failure(.expiredChallenge))
        #expect(fixture.confirmations == 0)
        let unsupported = Fixture([.success(.challenge(Self.challenge(["m.login.recaptcha"])))])
        let unsupportedService = try unsupported.service()
        #expect(await unsupportedService.begin(confirmed: true) == .failure(.unsupportedAuthentication))
    }

    @Test
    func confirmedSuccessSurvivesSyncRevokingSessionAndNavigationTeardown() async throws {
        let fixture = Fixture([])
        fixture.holdResponse = true
        let service = try fixture.service()
        let submission = Task { await service.begin(confirmed: true) }
        try await Self.waitUntil { fixture.continuation != nil }
        #expect(await service.begin(confirmed: true) == .failure(.cancelled))
        fixture.current = false // Sync has already revoked the token or the account has switched.
        service.close() // Native navigation teardown must not discard the observed HTTP 200.
        fixture.continuation?.resume(returning: .success(.success))
        #expect(await submission.value == .success(.success))
        #expect(fixture.confirmations == 1)
        #expect(fixture.requests.count == 1)
    }

    @Test
    func unknownOrCancelledOutcomeNeverRetriesOrShowsSuccess() async throws {
        for error in [CHIICHPasswordError.outcomeUnknown, .cancelled] {
            let fixture = Fixture([.failure(error)])
            let service = try fixture.service()
            #expect(await service.begin(confirmed: true) == .failure(.outcomeUnknown))
            #expect(await service.begin(confirmed: true) == .failure(.cancelled))
            #expect(fixture.requests.count == 1)
            #expect(fixture.confirmations == 0)
        }
    }

    @Test
    func accountSwitchBeforeSSOConfirmationCannotDeleteNewAccount() async throws {
        let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.sso"])))])
        let service = try fixture.service()
        _ = await service.begin(confirmed: true)
        let browser = try service.ssoPresentation().get()
        fixture.current = false
        #expect(!service.browserReturned(nonce: browser.id))
        #expect(await service.confirmSSO(nonce: browser.id) == .failure(.expiredChallenge))
        #expect(fixture.requests.count == 1)
        #expect(fixture.confirmations == 0)
    }

    @Test
    func screenDoesNotSendBeforeDestructiveConfirmationAndClearsPassword() async throws {
        let fixture = Fixture([.success(.challenge(Self.challenge(["m.login.password"]))), .success(.success)])
        let screen = try CHIICHDeletionScreenViewModel(service: fixture.service())
        screen.start()
        screen.process(viewAction: .requestDeletion)
        #expect(screen.state.bindings.confirmationShown)
        #expect(fixture.requests.isEmpty)
        screen.process(viewAction: .confirmDeletion)
        try await Self.waitUntil { screen.state.mode == .authentication }
        screen.state.bindings.currentPassword = "test-only"
        screen.process(viewAction: .submitPassword)
        #expect(screen.state.bindings.currentPassword.isEmpty)
        try await Self.waitUntil { screen.state.mode == .success }
        #expect(fixture.confirmations == 1)
        #expect(screen.state.challenge == nil)
    }

    private static func context() throws -> CHIICHPasswordContext {
        try #require(CHIICHPasswordContext(accountID: "@fixture:chat.chiich.one", deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one"))
    }
    private static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func challenge(_ stages: [String], session: String = "uia-test-only", completed: [String] = []) -> CHIICHPasswordChallenge {
        .init(session: session, flows: [.init(stages: stages)], completed: completed, errcode: nil)
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw CancellationError() }
            await Task.yield()
        }
    }
    private final class Fixture {
        var current = true
        var holdResponse = false
        var continuation: CheckedContinuation<CHIICHDeletionService.Submission, Never>?
        var requests: [CHIICHDeletionRequest] = []
        var responses: [CHIICHDeletionService.Submission]
        var confirmations = 0
        init(_ responses: [CHIICHDeletionService.Submission]) { self.responses = responses }
        func service(recovery: CHIICHDeletionRecovery? = nil) throws -> CHIICHDeletionService {
            CHIICHDeletionService(context: try CHIICHDeletionTests.context(),
                                  recovery: recovery,
                                  sessionIsCurrent: { [weak self] in self?.current == true },
                                  submitRequest: { [weak self] request in
                                      guard let self else { return .failure(.sessionChanged) }
                                      requests.append(request)
                                      if holdResponse { return await withCheckedContinuation { continuation = $0 } }
                                      guard !responses.isEmpty else { return .failure(.outcomeUnknown) }
                                      return responses.removeFirst()
                                  },
                                  confirmedSuccess: { [weak self] in self?.confirmations += 1 })
        }
    }
}
