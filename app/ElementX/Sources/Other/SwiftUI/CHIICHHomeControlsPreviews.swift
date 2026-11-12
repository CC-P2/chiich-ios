//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftUI

/// Settings layout snapshots supplement the real session-root captures in ChiichHomeControlsTests.
/// Navigation behaviour and search presentation are deliberately tested through the app coordinator.
struct ChiichHomeControls_Previews: PreviewProvider, TestablePreview {
    private static let userSession = makeUserSession()
    private static let settingsViewModel = SettingsScreenViewModel(userSession: userSession,
                                                                   isBugReportServiceEnabled: true,
                                                                   isInSecondaryWindow: false,
                                                                   userIndicatorController: UserIndicatorControllerMock())
    private static let homeViewModel = HomeScreenViewModel(userSession: userSession,
                                                           availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                                           selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                                           analyticsService: AnalyticsServiceMock(.init()),
                                                           bugReportService: BugReportServiceMock(.init()),
                                                           userIndicatorController: UserIndicatorControllerMock())
    
    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        settings
            .environment(\.colorScheme, .light)
            .previewDisplayName("Settings light")
        settings
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Settings graphite")
    }
    
    private static var settings: some View {
        ElementNavigationStack {
            SettingsScreen(context: settingsViewModel.context,
                           homeControls: .init(homeContext: homeViewModel.context,
                                               selectedSection: .constant(.chats),
                                               unreadChatCount: { 3 },
                                               openSearch: { }))
        }
        .snapshotPreferences(expect: settingsViewModel.context.observe(\.viewState.accountProfileURL).map { $0 != nil })
        .frame(height: 1700)
        .previewLayout(.sizeThatFits)
    }
    
    private static func makeUserSession() -> UserSessionMock {
        let userSettings = UserSettings.mock()
        userSettings.app.multiAccountEnabled = true
        userSettings.app.linkNewDeviceEnabled = true
        let clientProxy = ClientProxyMock(.init(userID: "@alice:example.com",
                                                deviceID: "AAAAAAAAAAA",
                                                displayName: "Alice Liddell",
                                                status: .mockFocussing,
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms))),
                                                spaceServiceConfiguration: .populated))
        return UserSessionMock(.init(clientProxy: clientProxy, userSettings: userSettings))
    }
}
