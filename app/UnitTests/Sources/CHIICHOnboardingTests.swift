//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CHIICHOnboardingTests {
    @Test
    func verifiedNewSessionFinishesBookkeepingWithoutPresentingSetup() {
        let fixture = OnboardingFixture(isNewLogin: true, verificationState: .verified)
        var presented = false
        var dismissed = false
        let subscription = fixture.coordinator.actions.sink {
            switch $0 {
            case .requestPresentation: presented = true
            case .dismiss: dismissed = true
            case .logoutConfirmed: Issue.record("Finishing onboarding must not log out.")
            }
        }
        #expect(fixture.coordinator.shouldStart)
        fixture.coordinator.start()
        
        withExtendedLifetime(subscription) {
            #expect(!presented)
            #expect(dismissed)
        }
        #expect(fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding)
        #expect(fixture.userSession.userSettings.app.hasSignedInBefore)
        #expect(!fixture.coordinator.shouldStart)
        #expect(fixture.navigationStack.rootCoordinator == nil)
    }
    
    @Test
    func verifiedRestoredSessionDoesNotRequestIdentityConfirmation() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .verified)
        #expect(!fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding)
        #expect(!fixture.coordinator.shouldStart)
    }
    
    @Test(arguments: [false, true])
    func unverifiedSessionStillRequiresNativeRecovery(hasCompletedOnboarding: Bool) {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .unverified)
        fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding = hasCompletedOnboarding
        #expect(fixture.coordinator.shouldStart)
        #expect(fixture.userSession.sessionSecurityStatePublisher.value.recoveryState == .enabled)
    }
    
    @Test
    func unknownNewDeviceStillRequiresIdentityConfirmation() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .unknown)
        #expect(fixture.coordinator.shouldStart)
        #expect(!fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding)
    }
    
    @Test
    func verifiedDeviceStillHonoursPendingNotificationPermission() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .verified)
        fixture.userSession.userSettings.account.enableNotifications = true
        fixture.userSession.userSettings.app.hasRunNotificationPermissionsOnboarding = false
        #expect(fixture.coordinator.shouldStart)
    }

    @Test
    func restoredAccountWithExplicitOptOutDoesNotGetAnInactiveNotificationPrompt() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .verified)
        fixture.userSession.userSettings.account.enableNotifications = false
        fixture.userSession.userSettings.app.hasRunNotificationPermissionsOnboarding = false
        #expect(!fixture.coordinator.shouldStart)
        #expect(!fixture.userSession.userSettings.account.enableNotifications)
        #expect(!fixture.userSession.userSettings.app.hasRunNotificationPermissionsOnboarding)
    }
    
    @Test
    func verifiedDeviceStillHonoursPendingAnalyticsConsent() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .verified, analyticsConsentRequired: true)
        #expect(fixture.coordinator.shouldStart)
    }

    @Test(arguments: [SessionVerificationState.unknown, .unverified])
    func plaintextNewLoginDoesNotPresentVerificationOrChangeSecurityState(verificationState: SessionVerificationState) {
        let fixture = OnboardingFixture(isNewLogin: true, verificationState: verificationState, forceDisableE2EE: true)
        var presented = false
        var dismissed = false
        let subscription = fixture.coordinator.actions.sink {
            switch $0 {
            case .requestPresentation: presented = true
            case .dismiss: dismissed = true
            case .logoutConfirmed: Issue.record("Deferring verification must not log out.")
            }
        }
        #expect(fixture.coordinator.shouldStart)
        fixture.coordinator.start()

        withExtendedLifetime(subscription) {
            #expect(!presented)
            #expect(dismissed)
        }
        #expect(fixture.navigationStack.rootCoordinator == nil)
        #expect(fixture.userSession.userSettings.app.hasSignedInBefore)
        #expect(!fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding)
        #expect(fixture.userSession.sessionSecurityStatePublisher.value.verificationState == verificationState)
        #expect(fixture.userSession.sessionSecurityStatePublisher.value.recoveryState == .enabled)
        #expect(!fixture.coordinator.shouldStart)
    }

    @Test(arguments: [SessionVerificationState.unknown, .unverified])
    func plaintextRestoredSessionDoesNotShowBlockingVerification(verificationState: SessionVerificationState) {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: verificationState, forceDisableE2EE: true)
        #expect(!fixture.coordinator.shouldStart)
        #expect(!fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding)
        #expect(fixture.userSession.sessionSecurityStatePublisher.value.verificationState == verificationState)
    }

    @Test
    func enablingEncryptionRestoresNativeVerificationGate() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .unverified, forceDisableE2EE: true)
        #expect(!fixture.coordinator.shouldStart)
        fixture.userSession.userSettings.app.forceDisableE2EE.applyRemoteValue(false)
        #expect(fixture.coordinator.shouldStart)
        #expect(!fixture.userSession.userSettings.account.hasRunIdentityConfirmationOnboarding)
    }

    @Test
    func plaintextPolicyDoesNotSkipPendingNotificationPermission() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .unverified, forceDisableE2EE: true)
        fixture.userSession.userSettings.account.enableNotifications = true
        fixture.userSession.userSettings.app.hasRunNotificationPermissionsOnboarding = false
        #expect(fixture.coordinator.shouldStart)
    }

    @Test
    func plaintextPolicyDoesNotSkipPendingAnalyticsConsent() {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .unverified,
                                        analyticsConsentRequired: true, forceDisableE2EE: true)
        #expect(fixture.coordinator.shouldStart)
    }

    @Test(arguments: [false, true])
    func incomingVerificationPresentationFollowsPlaintextPolicy(forceDisableE2EE: Bool) async throws {
        let fixture = OnboardingFixture(isNewLogin: false, verificationState: .verified, forceDisableE2EE: forceDisableE2EE)
        let client = try #require(fixture.userSession.clientProxy as? ClientProxyMock)
        let verification = SessionVerificationControllerProxyMock.configureMock()
        client.sessionVerificationController = verification
        let root = NavigationRootCoordinator()
        let sessionCoordinator = UserSessionFlowCoordinator(isNewLogin: false,
                                                            navigationRootCoordinator: root,
                                                            appLockService: AppLockServiceMock(),
                                                            flowParameters: fixture.flowParameters)
        sessionCoordinator.start()
        defer { sessionCoordinator.stop() }
        // Drain the initial security-state delivery, which installs the request observer.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let tabs = try #require(root.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>)
        let details = SessionVerificationRequestDetails(senderProfile: UserProfile(userID: client.userID),
                                                        flowID: "synthetic-verification", deviceID: "synthetic-device",
                                                        deviceDisplayName: "Test device", firstSeenDate: .now)
        if forceDisableE2EE {
            let unexpected = deferFailure(tabs.observe(\.sheetCoordinatorID), timeout: .milliseconds(200)) { $0 != nil }
            verification.actions.send(.receivedVerificationRequest(details: details))
            try await unexpected.fulfill()
            #expect(tabs.sheetCoordinator == nil)
        } else {
            let presented = deferFulfillment(tabs.observe(\.sheetCoordinatorID)) { $0 != nil }
            verification.actions.send(.receivedVerificationRequest(details: details))
            try await presented.fulfill()
            #expect((tabs.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is SessionVerificationScreenCoordinator)
        }
        #expect(fixture.userSession.sessionSecurityStatePublisher.value.verificationState == .verified)
    }
}

private struct OnboardingFixture {
    let userSession: UserSessionMock
    let navigationStack = NavigationStackCoordinator()
    let coordinator: OnboardingFlowCoordinator
    let flowParameters: CommonFlowParameters
    
    init(isNewLogin: Bool, verificationState: SessionVerificationState, analyticsConsentRequired: Bool = false,
         forceDisableE2EE: Bool = false) {
        userSession = UserSessionMock(.init())
        // Exercise the native encrypted policy explicitly in the older tests.
        userSession.userSettings.app.forceDisableE2EE.applyRemoteValue(forceDisableE2EE)
        userSession.userSettings.account.hasRunIdentityConfirmationOnboarding = false
        userSession.userSettings.app.hasSignedInBefore = false
        userSession.userSettings.app.hasRunNotificationPermissionsOnboarding = true
        userSession.sessionSecurityStatePublisher = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: verificationState,
                                                                                                           recoveryState: .enabled)).asCurrentValuePublisher()
        let appLockService = AppLockServiceMock()
        appLockService.isEnabled = false
        flowParameters = CommonFlowParameters(userSession: userSession,
                                              availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                              bugReportService: BugReportServiceMock(.init()),
                                              elementCallService: ElementCallServiceMock(.init()),
                                              timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                              emojiProvider: EmojiProvider(userSettings: userSession.userSettings),
                                              linkMetadataProvider: LinkMetadataProvider(),
                                              appMediator: AppMediatorMock(.init()),
                                              analytics: AnalyticsServiceMock(.init(shouldShowAnalyticsPrompt: analyticsConsentRequired)),
                                              userIndicatorController: UserIndicatorControllerMock(),
                                              stateMachineFactory: PublishedStateMachineFactory())
        coordinator = OnboardingFlowCoordinator(isNewLogin: isNewLogin,
                                                appLockService: appLockService,
                                                navigationStackCoordinator: navigationStack,
                                                flowParameters: flowParameters)
    }
}
