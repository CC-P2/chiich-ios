// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Combine
@testable import ElementX
import Foundation
import Testing

struct CHIICHIdentityRoutingTests {
    @Test(arguments: ["https://chiich.one/ivan2026", "https://chiich.one:443/IVAN2026", "one.chiich.app://user/IVAN2026"])
    func invitationUsesTheOrdinaryPendingSessionRoute(_ address: String) throws {
        let parser = AppRouteURLParser(appSettings: .volatile())
        let url = try #require(URL(string: address))
        let route = try #require(parser.route(from: url))
        #expect(route == .chiichPublicUsername(try CHIICHPublicUsername("ivan2026")))
        // AppCoordinator retains non-authentication routes until runPostSessionSetupTasks.
        #expect(!route.isAuthenticationRoute)
    }

    @Test(arguments: ["иван2026", "Ёжик123", "ivan123"])
    func sharedLinksRoundTripThroughBothOwnedSchemes(_ name: String) throws {
        let alias = try CHIICHPublicUsername(name)
        let parser = AppRouteURLParser(appSettings: .volatile())
        #expect(parser.route(from: alias.link) == .chiichPublicUsername(alias))
        #expect(parser.route(from: alias.appLink) == .chiichPublicUsername(alias))
    }

    @Test(arguments: ["http://chiich.one/ivan", "https://chiich.one.evil.invalid/ivan", "https://evil.invalid/ivan",
                      "https://user@chiich.one/ivan", "https://chiich.one:8448/ivan", "https://chiich.one/ivan/extra",
                      "https://chiich.one/ivan/", "https://chiich.one/ivan?token=synthetic", "https://chiich.one/ivan#fragment",
                      "https://chiich.one/ivan%2Fextra", "https://chiich.one/ivan%252Fextra", "https://chiich.one/",
                      "https://chiich.one/element.html", "https://chiich.one/login", "https://chiich.one/a",
                      "one.chiich.app://sso/ivan", "one.chiich.app://oauth/ivan", "one.chiich.app://user/ivan/extra",
                      "one.chiich.app://user@user/ivan", "one.chiich.app://user:443/ivan", "one.chiich.app://user/ivan?loginToken=synthetic",
                      "one.chiich.app://user/ivan#fragment", "one.chiich.app.evil://user/ivan", "one.chiich.app:/user/ivan"])
    func rejectsAmbiguousOrUnownedInvitationLinks(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(CHIICHPublicUsername.fromInvitationURL(url) == nil)
    }

    @Test
    func identityParserDoesNotInterceptNativeOAuthOrMatrixLinks() throws {
        let settings = AppSettings.volatile()
        let parser = AppRouteURLParser(appSettings: settings)
        let callback = settings.oAuthRedirectURL.appending(queryItems: [.init(name: "code", value: "synthetic")])
        #expect(parser.route(from: callback) == .oAuthCallback(url: callback))
        #expect(parser.route(from: "https://matrix.to/#/@alice:chat.chiich.one") == .userProfile(userID: "@alice:chat.chiich.one"))
        #expect(CHIICHPublicUsername.fromInvitationURL("one.chiich.app://sso/attempt?loginToken=synthetic") == nil)
    }

    @Test
    func resolvedInvitationOpensTheNativeProfileWithoutCreatingARoom() async throws {
        let fixture = Fixture()
        let opened = deferFulfillment(fixture.profileRequests) { $0 == "@bob:chat.chiich.one" }
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("oldname")), animated: false)
        try await opened.fulfill()
        let split = try #require(fixture.split)
        let presented = deferFulfillment(split.observe(\.sheetCoordinatorID)) { $0 != nil }
        try await presented.fulfill()
        #expect((split.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is UserProfileScreenCoordinator)
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
        #expect(fixture.requests == [.resolve(try CHIICHPublicUsername("oldname"))])
        #expect(fixture.root.alertInfo == nil)
    }

    @Test(arguments: [false, true])
    func laterNavigationOrStoppedSessionDropsThePendingRecipient(_ stopSession: Bool) async throws {
        let fixture = Fixture()
        fixture.holdResolve = true
        let started = deferFulfillment(fixture.pendingPublisher) { $0 }
        let unexpected = deferFailure(fixture.profileRequests, timeout: .milliseconds(200)) { _ in true }
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("oldname")), animated: false)
        try await started.fulfill()
        if stopSession { fixture.coordinator.stop() }
        else { fixture.coordinator.handleAppRoute(.roomList, animated: false) }
        fixture.resumeResolve()
        try await unexpected.fulfill()
        let split = try #require(fixture.split)
        #expect(split.sheetCoordinator == nil)
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
    }

    @Test
    func expiredSessionCannotDisplayALateResolvedRecipient() async throws {
        let fixture = Fixture()
        fixture.holdResolve = true
        let started = deferFulfillment(fixture.pendingPublisher) { $0 }
        let unexpected = deferFailure(fixture.profileRequests, timeout: .milliseconds(200)) { _ in true }
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("oldname")), animated: false)
        try await started.fulfill()
        fixture.client.chiichReceiverAIIsSessionActive = false
        fixture.resumeResolve()
        try await unexpected.fulfill()
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
    }

    @Test(arguments: [false, true])
    func pendingRecipientSurvivesVerificationAfterLoginOrSessionRestore(_ isNewLogin: Bool) async throws {
        let fixture = Fixture(verificationState: .unknown, isNewLogin: isNewLogin)
        let tabs = try #require(fixture.tabs)
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("oldname")), animated: false)
        #expect(fixture.requests.isEmpty)
        let onboarding = deferFulfillment(tabs.observe(\.chiichHasOnboardingCover)) { $0 }
        fixture.securityState.send(.init(verificationState: .unverified, recoveryState: .enabled))
        try await onboarding.fulfill()
        #expect(fixture.requests.isEmpty)
        let opened = deferFulfillment(fixture.profileRequests) { $0 == "@bob:chat.chiich.one" }
        fixture.securityState.send(.init(verificationState: .verified, recoveryState: .enabled))
        try await opened.fulfill()
        #expect(!tabs.chiichHasOnboardingCover)
        #expect(fixture.requests == [.resolve(try CHIICHPublicUsername("oldname"))])
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
    }

    @Test(arguments: [SessionVerificationState.unknown, .unverified], [false, true])
    func plaintextInvitationDoesNotWaitForCryptographicVerification(_ verificationState: SessionVerificationState, _ isNewLogin: Bool) async throws {
        let fixture = Fixture(verificationState: verificationState, isNewLogin: isNewLogin, forceDisableE2EE: true)
        let tabs = try #require(fixture.tabs)
        let opened = deferFulfillment(fixture.profileRequests) { $0 == "@bob:chat.chiich.one" }
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("oldname")), animated: false)
        try await opened.fulfill()
        #expect(!tabs.chiichHasOnboardingCover)
        #expect(fixture.securityState.value.verificationState == verificationState)
        #expect(fixture.requests == [.resolve(try CHIICHPublicUsername("oldname"))])
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
    }

    @Test(arguments: [false, true])
    func navigationOrLogoutDuringVerificationCancelsTheRetainedRecipient(_ stopSession: Bool) async throws {
        let fixture = Fixture(verificationState: .unknown)
        let tabs = try #require(fixture.tabs)
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("oldname")), animated: false)
        let onboarding = deferFulfillment(tabs.observe(\.chiichHasOnboardingCover)) { $0 }
        fixture.securityState.send(.init(verificationState: .unverified, recoveryState: .enabled))
        try await onboarding.fulfill()
        if stopSession { fixture.coordinator.stop() }
        else { fixture.coordinator.handleAppRoute(.roomList, animated: false) }
        let unexpected = deferFailure(fixture.profileRequests, timeout: .milliseconds(200)) { _ in true }
        fixture.securityState.send(.init(verificationState: .verified, recoveryState: .enabled))
        try await unexpected.fulfill()
        #expect(fixture.requests.isEmpty)
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
    }

    @Test
    func missingRecipientPresentsNativeRetryAndDoesNotCreateAnAccountOrRoom() async throws {
        let fixture = Fixture()
        fixture.response = .failure(.notFound)
        let error = deferFulfillment(fixture.root.observe(\.alertInfo)) { $0 != nil }
        fixture.coordinator.handleAppRoute(.chiichPublicUsername(try CHIICHPublicUsername("deleted")), animated: false)
        try await error.fulfill()
        #expect(fixture.root.alertInfo?.message == L10n.screenChiichIdentityNotFound)
        #expect(fixture.root.alertInfo?.primaryButton.title == L10n.actionRetry)
        #expect(fixture.client.createDirectRoomWithExpectedRoomNameCallsCount == 0)
    }

    private final class Fixture {
        let client = ClientProxyMock(.init(homeserver: "https://matrix.chiich.one", userID: "@alice:chat.chiich.one", deviceID: "ONE"))
        let root = NavigationRootCoordinator()
        let profileRequests = PassthroughSubject<String, Never>()
        let pendingPublisher = CurrentValueSubject<Bool, Never>(false)
        let securityState: CurrentValueSubject<SessionSecurityState, Never>
        var requests: [CHIICHIdentityRequest] = []
        var holdResolve = false
        var response: Result<Data, CHIICHIdentityError> = .success(Data(#"{"username":"newname","user_id":"@bob:chat.chiich.one"}"#.utf8))
        private var pending: CheckedContinuation<Result<Data, CHIICHIdentityError>, Never>?
        let coordinator: UserSessionFlowCoordinator

        var tabs: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>? {
            root.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>
        }

        var split: NavigationSplitCoordinator? { tabs?.tabCoordinators.first as? NavigationSplitCoordinator }

        init(verificationState: SessionVerificationState = .verified, isNewLogin: Bool = false, forceDisableE2EE: Bool = false) {
            client.chiichReceiverAIIsSessionActive = true
            let userSession = UserSessionMock(.init(clientProxy: client))
            // Keep mandatory encrypted onboarding in the original routing tests.
            userSession.userSettings.app.forceDisableE2EE.applyRemoteValue(forceDisableE2EE)
            securityState = .init(.init(verificationState: verificationState, recoveryState: .enabled))
            userSession.sessionSecurityStatePublisher = securityState.asCurrentValuePublisher()
            userSession.userSettings.account.hasRunIdentityConfirmationOnboarding = !isNewLogin
            userSession.userSettings.app.hasRunNotificationPermissionsOnboarding = true
            let parameters = CommonFlowParameters(userSession: userSession,
                                                   availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                                   bugReportService: BugReportServiceMock(.init()),
                                                   elementCallService: ElementCallServiceMock(.init()),
                                                   timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                   emojiProvider: EmojiProvider(userSettings: userSession.userSettings),
                                                   linkMetadataProvider: LinkMetadataProvider(),
                                                   appMediator: AppMediatorMock(.init()),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: UserIndicatorControllerMock(),
                                                   stateMachineFactory: PublishedStateMachineFactory())
            coordinator = UserSessionFlowCoordinator(isNewLogin: isNewLogin,
                                                      navigationRootCoordinator: root,
                                                      appLockService: AppLockServiceMock(),
                                                      flowParameters: parameters)
            client.chiichIdentityRequestAccountIDClosure = { [weak self] request, accountID in
                guard let self else { return .failure(.sessionChanged) }
                #expect(accountID == "@alice:chat.chiich.one")
                requests.append(request)
                if holdResolve {
                    return await withCheckedContinuation { continuation in
                        pending = continuation
                        pendingPublisher.send(true)
                    }
                }
                return response
            }
            client.profileForClosure = { [weak self] userID in
                self?.profileRequests.send(userID)
                return .success(UserProfile(userID: userID, displayName: "Bob"))
            }
            coordinator.start()
        }

        func resumeResolve() {
            pending?.resume(returning: response)
            pending = nil
        }
    }
}

private extension NavigationTabCoordinator {
    var chiichHasOnboardingCover: Bool { fullScreenCoverCoordinator != nil }
}
