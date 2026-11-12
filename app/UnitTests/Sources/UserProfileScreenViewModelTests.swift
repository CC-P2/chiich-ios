//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct UserProfileScreenViewModelTests {
    @Test
    func initialState() async throws {
        let userIndicatorController = UserIndicatorControllerMock()
        
        let profile = UserProfile(userID: "@alice:matrix.org", displayName: "Alice", avatarURL: .mockMXCAvatar)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.profileForReturnValue = .success(profile)
        
        let viewModel = UserProfileScreenViewModel(userID: profile.id,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: userIndicatorController)
        let context = viewModel.context
        
        let waitForMemberToLoad = deferFulfillment(context.observe(\.viewState.userProfile)) { $0 != nil }
        try await waitForMemberToLoad.fulfill()
        
        #expect(!context.viewState.isOwnUser)
        #expect(context.viewState.userProfile == profile)
        #expect(context.viewState.permalink != nil)
    }
    
    @Test
    func initialStateAccountOwner() async throws {
        let userIndicatorController = UserIndicatorControllerMock()
        
        let profile = UserProfile(userID: RoomMemberProxyMock.mockMe.userID, displayName: "Me", avatarURL: .mockMXCAvatar)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.profileForReturnValue = .success(profile)
        
        let viewModel = UserProfileScreenViewModel(userID: profile.id,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: userIndicatorController)
        let context = viewModel.context
        
        let waitForMemberToLoad = deferFulfillment(context.observe(\.viewState.userProfile)) { $0 != nil }
        try await waitForMemberToLoad.fulfill()
        
        #expect(context.viewState.isOwnUser)
        #expect(context.viewState.userProfile == profile)
        #expect(context.viewState.permalink != nil)
    }

    @Test
    func chiichAccountOwnerSharesOnlyTheirConfirmedShortLink() async throws {
        let client = ClientProxyMock(.init(homeserver: "https://matrix.chiich.one", userID: "@a__id123:chat.chiich.one", deviceID: "ONE"))
        client.chiichReceiverAIIsSessionActive = true
        client.profileForReturnValue = .success(UserProfile(userID: client.userID, displayName: "Ivan"))
        client.userIdentityForFallBackToServerReturnValue = .success(UserIdentityProxyMock(.init(verificationState: .verified)))
        client.chiichIdentityRequestAccountIDReturnValue = .success(Data(#"{"username":"ivan","display_username":"Ivan"}"#.utf8))
        let viewModel = UserProfileScreenViewModel(userID: client.userID,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: client)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: UserIndicatorControllerMock())
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.isVerified)) { $0 == true }
        try await loaded.fulfill()
        #expect(viewModel.context.viewState.permalink?.absoluteString == "https://chiich.one/Ivan")
        #expect(viewModel.context.viewState.chiichDisplayUsername == "Ivan")
        #expect(viewModel.context.viewState.userProfile?.id == client.userID)
        #expect(client.chiichIdentityRequestAccountIDCallsCount == 1)
    }

    @Test(arguments: [#"{"username":null,"display_username":null}"#, #"{"username":"user12345678"}"#])
    func unchosenOrLegacyResponseNeverSharesTheGeneratedAccountID(_ response: String) async throws {
        let client = ClientProxyMock(.init(homeserver: "https://matrix.chiich.one", userID: "@a__id123:chat.chiich.one", deviceID: "ONE"))
        client.chiichReceiverAIIsSessionActive = true
        client.profileForReturnValue = .success(UserProfile(userID: client.userID, displayName: "Ivan"))
        client.userIdentityForFallBackToServerReturnValue = .success(UserIdentityProxyMock(.init(verificationState: .verified)))
        client.chiichIdentityRequestAccountIDReturnValue = .success(Data(response.utf8))
        let viewModel = UserProfileScreenViewModel(userID: client.userID,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: client)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: UserIndicatorControllerMock())
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.isVerified)) { $0 == true }
        try await loaded.fulfill()
        #expect(viewModel.context.viewState.permalink == nil)
        #expect(viewModel.context.viewState.chiichDisplayUsername == L10n.screenChiichIdentityChooseUsername)
        #expect(viewModel.context.viewState.userProfile?.id == client.userID)
    }

    @Test
    func anotherPersonsProfileNeverUsesTheAccountOwnersAlias() async throws {
        let client = ClientProxyMock(.init(homeserver: "https://matrix.chiich.one", userID: "@a__id123:chat.chiich.one", deviceID: "ONE"))
        client.chiichReceiverAIIsSessionActive = true
        let recipient = UserProfile(userID: "@other:chat.chiich.one", displayName: "Other")
        client.profileForReturnValue = .success(recipient)
        client.chiichIdentityRequestAccountIDReturnValue = .success(Data(#"{"username":"ivan","display_username":"Ivan"}"#.utf8))
        let viewModel = UserProfileScreenViewModel(userID: recipient.id,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: client)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: UserIndicatorControllerMock())
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.userProfile)) { $0 != nil }
        try await loaded.fulfill()
        #expect(viewModel.context.viewState.chiichDisplayUsername == nil)
        #expect(viewModel.context.viewState.permalink?.host() == "matrix.to")
        #expect(client.chiichIdentityRequestAccountIDCallsCount == 0)
    }

    @Test
    func unavailableOwnedIdentityServiceDoesNotFallBackToSharingTheAccountID() async throws {
        let client = ClientProxyMock(.init(homeserver: "https://unsupported.invalid", userID: "@a__id123:chat.chiich.one", deviceID: "ONE"))
        client.chiichReceiverAIIsSessionActive = true
        client.profileForReturnValue = .success(UserProfile(userID: client.userID, displayName: "Ivan"))
        client.userIdentityForFallBackToServerReturnValue = .success(UserIdentityProxyMock(.init(verificationState: .verified)))
        let viewModel = UserProfileScreenViewModel(userID: client.userID,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: client)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: UserIndicatorControllerMock())
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.isVerified)) { $0 == true }
        try await loaded.fulfill()
        #expect(viewModel.context.viewState.permalink == nil)
        #expect(viewModel.context.viewState.chiichDisplayUsername == L10n.screenChiichIdentityChooseUsername)
        #expect(client.chiichIdentityRequestAccountIDCallsCount == 0)
    }
    
    @Test
    func startingDmWithUnknownUserFetchesIdentity() async throws {
        let userIndicatorController = UserIndicatorControllerMock()
        
        let profile = UserProfile.mockAlice
        
        let clientProxy = ClientProxyMock(.init())
        clientProxy.directRoomForUserIDReturnValue = .success(nil)
        clientProxy.userIdentityForFallBackToServerReturnValue = .success(nil)
        
        let viewModel = UserProfileScreenViewModel(userID: profile.id,
                                                   isPresentedModally: false,
                                                   userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                   analytics: AnalyticsServiceMock(.init()),
                                                   userIndicatorController: userIndicatorController)
        
        let context = viewModel.context
        
        let waitForMemberToLoad = deferFulfillment(context.observe(\.viewState.userProfile)) { $0 != nil }
        try await waitForMemberToLoad.fulfill()
        
        let deferred = deferFulfillment(context.observe(\.viewState.bindings.inviteConfirmationUser), timeout: .seconds(5)) { $0?.isUnknown == true }
        
        context.send(viewAction: .openDirectChat)
        try await deferred.fulfill()
    }
}
