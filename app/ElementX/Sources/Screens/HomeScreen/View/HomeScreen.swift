//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SentrySwiftUI
import SwiftUI

struct HomeScreen: View {
    @Environment(\.isInSidebar) private var isInSidebar
    
    @ObservedObject var context: HomeScreenViewModel.Context
    
    @State private var scrollViewAdapter = ScrollViewAdapter()
    
    var body: some View {
        HomeScreenContent(context: context, scrollViewAdapter: scrollViewAdapter)
            .safeAreaInset(edge: .top, spacing: 0) { CHIICHPlannerStrip() }
            .overlay(alignment: .bottomTrailing) { searchButton }
            .alert(item: $context.alertInfo)
            .alert(item: $context.leaveRoomAlertItem,
                   actions: leaveRoomAlertActions,
                   message: leaveRoomAlertMessage)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarRole(Compound.supportsGlass ? .editor : .automatic)
            .toolbarBackground(CHIICHTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .track(screen: .Home)
            .sentryTrace("\(Self.self)")
            .sheet(isPresented: $context.isPresentingMultiAccountAnnouncement) {
                MultiAccountAnnouncementView(context: context)
                    .onAppear { context.send(viewAction: .multiAccountAnnouncementAppeared) }
            }
            .onAppear { context.send(viewAction: .screenAppeared) }
    }
    
    // MARK: - Private
    
    private var title: String {
        if let selectedSpace = context.viewState.selectedSpaceFilter {
            selectedSpace.room.name
        } else {
            "CHIICH"
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: Compound.supportsGlass ? .title : .navigationBarLeading) {
            HStack(spacing: isInSidebar ? 8 : 12) {
                // The settings button is inside the title on iOS 26 to workaround a
                // weird liquid glass transition when pushing/popping a room.
                settingsButton
                    .buttonStyle(.borderless)
                
                if #available(iOS 26, *) {
                    Text(title)
                        .font(.compound.bodyLGSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .minimumScaleFactor(isInSidebar ? 1 : 0.6) // Allow scaling down to bodyLG if needed.
                }
            }
        }
        .backportSharedBackgroundVisibility(.hidden)
        
        ToolbarItem(placement: .primaryAction) {
            if #available(iOS 26, *) {
                newRoomButton
            } else {
                newRoomButton
                    .buttonStyle(.compound(.super, size: .toolbarIcon))
            }
        }
    }
    
    private var settingsButton: some View {
        Button {
            context.send(viewAction: .showSettings)
        } label: {
            CHIICHBrandMark(isActive: context.viewState.chiichReceiverAI?.isActive == true)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(L10n.commonSettings)
        .accessibilityIdentifier(A11yIdentifiers.homeScreen.userAvatar)
    }
    
    @ViewBuilder
    private var searchButton: some View {
        if !context.viewState.isRoomListSearchEnabled, !context.isSearchFieldFocused, context.viewState.roomListMode == .rooms {
            Button { context.send(viewAction: .showSearch) } label: {
                CompoundIcon(\.search)
                    .foregroundStyle(CHIICHTheme.accent)
                    .frame(width: 56, height: 56)
                    .background(CHIICHTheme.paper, in: Circle())
                    .overlay { Circle().stroke(CHIICHTheme.line, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.screenHomeTabSearch)
            .accessibilityIdentifier("chiich.home.search")
            .padding(16)
        }
    }
    
    @ViewBuilder
    private var newRoomButton: some View {
        switch context.viewState.roomListMode {
        case .empty, .rooms:
            Button {
                context.send(viewAction: .startChat)
            } label: {
                CompoundIcon(\.plus)
                    .foregroundStyle(.compound.iconPrimary)
            }
            .accessibilityLabel(L10n.actionStartChat)
            .accessibilityIdentifier(A11yIdentifiers.homeScreen.startChat)
        default:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func leaveRoomAlertActions(_ item: LeaveRoomAlertItem) -> some View {
        Button(item.cancelTitle, role: .cancel) { }
        Button(item.confirmationTitle, role: .destructive) {
            context.send(viewAction: .confirmLeaveRoom(roomIdentifier: item.roomID))
        }
    }
    
    private func leaveRoomAlertMessage(_ item: LeaveRoomAlertItem) -> some View {
        Text(item.subtitle)
    }
}

// MARK: - Previews

struct HomeScreen_Previews: PreviewProvider, TestablePreview {
    static let loadingViewModel = viewModel(.skeletons)
    static let emptyViewModel = viewModel(.empty)
    static let loadedViewModel = viewModel(.rooms)
    
    static var previews: some View {
        ElementNavigationStack {
            HomeScreen(context: loadingViewModel.context)
        }
        .snapshotPreferences(expect: loadingViewModel.context.$viewState.map { state in
            state.roomListMode == .skeletons
        })
        .previewDisplayName("Loading")
        
        ElementNavigationStack {
            HomeScreen(context: emptyViewModel.context)
        }
        .snapshotPreferences(expect: emptyViewModel.context.$viewState.map { state in
            state.roomListMode == .empty
        })
        .previewDisplayName("Empty")
        
        ElementNavigationStack {
            HomeScreen(context: loadedViewModel.context)
        }
        .snapshotPreferences(expect: loadedViewModel.context.$viewState.map { state in
            state.roomListMode == .rooms
        })
        .previewDisplayName("Loaded")
    }
    
    static func viewModel(_ mode: HomeScreenRoomListMode) -> HomeScreenViewModel {
        let userID = "@alice:example.com"
        
        let roomSummaryProviderState: RoomSummaryProviderMockConfigurationState = switch mode {
        case .awaitingCachedRooms, .skeletons:
            .loading
        case .empty:
            .loaded([])
        case .rooms:
            .loaded(.mockRooms)
        }
        
        let clientProxy = ClientProxyMock(.init(userID: userID,
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: roomSummaryProviderState))))
        
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        
        return HomeScreenViewModel(userSession: userSession,
                                   availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                   selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                   analyticsService: AnalyticsServiceMock(.init()),
                                   bugReportService: BugReportServiceMock(.init()),
                                   userIndicatorController: UserIndicatorControllerMock())
    }
}
