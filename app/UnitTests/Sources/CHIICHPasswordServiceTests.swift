// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

final class CHIICHPasswordServiceTests {
    @Test
    func firstPasswordUsesSSOWithoutInventingAnOldPassword() async throws {
        let fixture = Fixture(responses: [.success(.challenge(Self.challenge(["m.login.sso"]))), .success(.success)])
        let service = try fixture.makeService()
        let initial = await service.begin(newPassword: Self.password, confirmation: Self.password)
        #expect(initial == .success(.challenge(Self.challenge(["m.login.sso"]))))
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests[0].authentication == nil)
        let browser = try service.ssoPresentation().get()
        #expect(!service.browserReturned(nonce: UUID()))
        #expect(await service.confirmSSO(nonce: browser.id) == .failure(.expiredChallenge))
        #expect(fixture.requests.count == 1)
        #expect(service.browserReturned(nonce: browser.id))
        #expect(fixture.requests.count == 1) // A browser close never submits or reports success.
        #expect(await service.confirmSSO(nonce: browser.id) == .success(.success))
        guard case .session("uia-test-only")? = fixture.requests[1].authentication else {
            Issue.record("SSO must resubmit the original UIA session, not a login token.")
            return
        }
    }

    @Test
    func cancelledOrRejectedBrowserAuthenticationDoesNotBecomeSuccess() async throws {
        let challenge = Self.challenge(["m.login.sso"])
        let fixture = Fixture(responses: [.success(.challenge(challenge)), .success(.challenge(challenge))])
        let service = try fixture.makeService()
        _ = await service.begin(newPassword: Self.password, confirmation: Self.password)
        let browser = try service.ssoPresentation().get()
        #expect(service.browserReturned(nonce: browser.id))
        #expect(await service.confirmSSO(nonce: browser.id) == .success(.challenge(challenge)))
        #expect(fixture.requests.count == 2)
        await Task.yield()
        #expect(fixture.requests.count == 2)
    }

    @Test
    func retryingCurrentPasswordKeepsTheSameNewPasswordAndUIASession() async throws {
        let challenge = Self.challenge(["m.login.password"])
        let rejected = CHIICHPasswordChallenge(session: challenge.session, flows: challenge.flows, completed: [], errcode: "M_FORBIDDEN")
        let fixture = Fixture(responses: [.success(.challenge(challenge)), .success(.challenge(rejected)), .success(.success)])
        let service = try fixture.makeService()
        _ = await service.begin(newPassword: Self.password, confirmation: Self.password)
        #expect(await service.submitPassword("") == .failure(.currentPasswordRequired))
        #expect(fixture.requests.count == 1)
        #expect(await service.submitPassword("wrong-test-only") == .success(.challenge(rejected)))
        #expect(await service.submitPassword("old-test-only") == .success(.success))
        #expect(fixture.requests.allSatisfy { $0.newPassword == Self.password })
        #expect(fixture.requests.dropFirst().allSatisfy { $0.authentication?.sessionID == "uia-test-only" })
    }

    @Test
    func multiStageUIARequiresEveryAdvertisedStage() async throws {
        let initial = Self.challenge(["m.login.password", "m.login.sso"])
        let afterPassword = Self.challenge(["m.login.password", "m.login.sso"], completed: ["m.login.password"])
        let fixture = Fixture(responses: [.success(.challenge(initial)), .success(.challenge(afterPassword)), .success(.success)])
        let service = try fixture.makeService()
        _ = await service.begin(newPassword: Self.password, confirmation: Self.password)
        #expect(service.ssoPresentation() == .failure(.expiredChallenge))
        #expect(await service.submitPassword("old-test-only") == .success(.challenge(afterPassword)))
        let browser = try service.ssoPresentation().get()
        #expect(service.browserReturned(nonce: browser.id))
        #expect(await service.confirmSSO(nonce: browser.id) == .success(.success))
        #expect(fixture.requests.count == 3)
    }

    @Test
    func unknownUIAStagesAreNotReinterpretedAsSupportedAuthentication() async throws {
        let fixture = Fixture(responses: [.success(.challenge(Self.challenge(["m.login.recaptcha"]))), .success(.success)])
        let service = try fixture.makeService()
        #expect(await service.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.unsupportedAuthentication))
        #expect(service.ssoPresentation() == .failure(.sessionChanged))
        #expect(fixture.requests.count == 1)
    }

    @Test
    func serverChangingUIASessionCannotRebindThePendingPassword() async throws {
        let fixture = Fixture(responses: [.success(.challenge(Self.challenge(["m.login.password"]))),
                                          .success(.challenge(Self.challenge(["m.login.password"], session: "different-test-session")))])
        let service = try fixture.makeService()
        _ = await service.begin(newPassword: Self.password, confirmation: Self.password)
        #expect(await service.submitPassword("old-test-only") == .failure(.expiredChallenge))
        #expect(fixture.requests.count == 2)
    }

    @Test
    func onlyExplicitDisabledCapabilityBlocksFirstPassword() async throws {
        let disabled = Fixture(responses: [.success(.success)])
        disabled.capability = .disabled
        let disabledService = try disabled.makeService()
        #expect(await disabledService.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.serverDisabled))
        #expect(disabled.requests.isEmpty)

        let unknown = Fixture(responses: [.success(.success)])
        unknown.capability = .unknown
        let unknownService = try unknown.makeService()
        #expect(await unknownService.begin(newPassword: Self.password, confirmation: Self.password) == .success(.success))
        #expect(unknown.requests.count == 1)
    }

    @Test
    func doubleSubmitWhileCapabilitiesAreLoadingProducesOneTransaction() async throws {
        let fixture = Fixture(responses: [.success(.success)])
        fixture.holdCapability = true
        let service = try fixture.makeService()
        let task = Task { await service.begin(newPassword: Self.password, confirmation: Self.password) }
        try await Self.waitUntil { fixture.capabilityContinuation != nil }
        #expect(await service.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.cancelled))
        fixture.capabilityContinuation?.resume(returning: .allowed)
        fixture.capabilityContinuation = nil
        #expect(await task.value == .success(.success))
        #expect(fixture.requests.count == 1)
    }

    @Test
    func cancellationDiscardsLateSuccessAndNeverResubmits() async throws {
        let fixture = Fixture(responses: [])
        fixture.holdResponse = true
        let service = try fixture.makeService()
        let task = Task { await service.begin(newPassword: Self.password, confirmation: Self.password) }
        try await Self.waitUntil { fixture.responseContinuation != nil }
        service.cancel()
        fixture.responseContinuation?.resume(returning: .success(.success))
        fixture.responseContinuation = nil
        #expect(await task.value == .failure(.cancelled))
        #expect(await service.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.cancelled))
        #expect(fixture.requests.count == 1)
    }

    @Test
    func sessionChangeBeforeOrAfterResponseCannotCompleteAnotherAccountOperation() async throws {
        let before = Fixture(responses: [.success(.success)])
        let beforeService = try before.makeService()
        before.sessionActive = false
        #expect(await beforeService.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.sessionChanged))
        #expect(before.requests.isEmpty)

        let during = Fixture(responses: [.success(.success)])
        during.invalidateOnSubmission = true
        let duringService = try during.makeService()
        #expect(await duringService.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.sessionChanged))
        #expect(during.requests.count == 1)
    }

    @Test
    func browserNonceCannotBeReusedAfterReopeningOrSessionChange() async throws {
        let fixture = Fixture(responses: [.success(.challenge(Self.challenge(["m.login.sso"])))])
        let service = try fixture.makeService()
        _ = await service.begin(newPassword: Self.password, confirmation: Self.password)
        let first = try service.ssoPresentation().get()
        let second = try service.ssoPresentation().get()
        #expect(first.id != second.id)
        #expect(!service.browserReturned(nonce: first.id))
        fixture.sessionActive = false
        #expect(!service.browserReturned(nonce: second.id))
        #expect(fixture.requests.count == 1)
    }

    @Test
    func uncertainPasswordChangeIsNotAutomaticallyRetried() async throws {
        let fixture = Fixture(responses: [.failure(.outcomeUnknown)])
        let service = try fixture.makeService()
        #expect(await service.begin(newPassword: Self.password, confirmation: Self.password) == .failure(.outcomeUnknown))
        await Task.yield()
        #expect(fixture.requests.count == 1)
        #expect(await service.submitPassword("old-test-only") == .failure(.expiredChallenge))
    }

    @Test
    func nativeScreenClearsFieldsAndDoesNotTreatBrowserReturnAsSuccess() async throws {
        let fixture = Fixture(responses: [.success(.challenge(Self.challenge(["m.login.sso"])))])
        let viewModel = try CHIICHPasswordScreenViewModel(service: fixture.makeService())
        viewModel.start()
        try await Self.waitUntil { viewModel.state.mode == .entry }
        viewModel.state.bindings.newPassword = Self.password
        viewModel.state.bindings.confirmation = Self.password
        viewModel.process(viewAction: .save)
        #expect(viewModel.state.bindings.newPassword.isEmpty)
        #expect(viewModel.state.bindings.confirmation.isEmpty)
        try await Self.waitUntil { viewModel.state.mode == .authentication }
        viewModel.process(viewAction: .openSSO)
        let browser = try #require(viewModel.state.bindings.browser)
        viewModel.process(viewAction: .browserReturned(UUID()))
        #expect(viewModel.state.bindings.browser?.id == browser.id)
        viewModel.process(viewAction: .browserSheetDismissed)
        #expect(viewModel.state.returnedBrowserNonce == browser.id)
        #expect(viewModel.state.mode == .authentication)
        #expect(fixture.requests.count == 1)
        viewModel.stop()
        #expect(viewModel.state.bindings.browser == nil)
        #expect(viewModel.state.challenge == nil)
        #expect(viewModel.state.returnedBrowserNonce == nil)
    }

    @Test
    func nativeScreenRequiresServerSuccessBeforeShowingSaved() async throws {
        let challenge = Self.challenge(["m.login.password"])
        let fixture = Fixture(responses: [.success(.challenge(challenge)), .success(.success)])
        let viewModel = try CHIICHPasswordScreenViewModel(service: fixture.makeService())
        viewModel.start()
        try await Self.waitUntil { viewModel.state.mode == .entry }
        viewModel.state.bindings.newPassword = Self.password
        viewModel.state.bindings.confirmation = Self.password
        viewModel.process(viewAction: .save)
        try await Self.waitUntil { viewModel.state.mode == .authentication }
        #expect(viewModel.state.bindings.currentPassword.isEmpty)
        viewModel.state.bindings.currentPassword = "old-test-only"
        viewModel.process(viewAction: .submitPassword)
        #expect(viewModel.state.bindings.currentPassword.isEmpty)
        try await Self.waitUntil { viewModel.state.mode == .success }
        #expect(fixture.requests.count == 2)
        #expect(viewModel.state.challenge == nil)
    }

    private static let password = "new-password-test-only"

    private static func challenge(_ stages: [String], session: String = "uia-test-only", completed: [String] = []) -> CHIICHPasswordChallenge {
        .init(session: session, flows: [.init(stages: stages)], completed: completed, errcode: nil)
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            if ContinuousClock.now >= deadline {
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    private final class Fixture {
        var capability = CHIICHPasswordCapability.allowed
        var sessionActive = true
        var invalidateOnSubmission = false
        var holdCapability = false
        var holdResponse = false
        var capabilityContinuation: CheckedContinuation<CHIICHPasswordCapability, Never>?
        var responseContinuation: CheckedContinuation<CHIICHPasswordService.Submission, Never>?
        var responses: [CHIICHPasswordService.Submission]
        var requests: [CHIICHPasswordRequest] = []

        init(responses: [CHIICHPasswordService.Submission]) {
            self.responses = responses
        }

        func makeService() throws -> CHIICHPasswordService {
            let context = try #require(CHIICHPasswordContext(accountID: "@alice:chat.chiich.one", deviceID: "TEST-DEVICE", homeserver: "https://matrix.chiich.one"))
            return CHIICHPasswordService(context: context,
                                         sessionIsCurrent: { [weak self] in self?.sessionActive == true },
                                         capabilityRequest: { [weak self] in
                                             guard let self else { return .unknown }
                                             if holdCapability { return await withCheckedContinuation { capabilityContinuation = $0 } }
                                             return capability
                                         },
                                         submitRequest: { [weak self] request in
                                             guard let self else { return .failure(.sessionChanged) }
                                             requests.append(request)
                                             if holdResponse { return await withCheckedContinuation { responseContinuation = $0 } }
                                             if invalidateOnSubmission { sessionActive = false }
                                             guard !responses.isEmpty else { return .failure(.invalidResponse) }
                                             return responses.removeFirst()
                                         })
        }
    }
}
