//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

enum CHIICHHomeSection: Hashable {
    case chats
    case spaces
}

/// Settings operates on the existing Home state and native tab selection, never a copy of either.
struct CHIICHHomeControlsContext {
    let homeContext: HomeScreenViewModel.Context
    var selectedSection: Binding<CHIICHHomeSection>
    var unreadChatCount: () -> Int = { 0 }
    var openSearch: (() -> Void)?
}

struct CHIICHHomeControlsSection: View {
    @ObservedObject private var context: HomeScreenViewModel.Context
    @Binding private var selectedSection: CHIICHHomeSection
    private let unreadChatCount: () -> Int
    private let openSearch: (() -> Void)?
    
    init(controls: CHIICHHomeControlsContext) {
        context = controls.homeContext
        _selectedSection = controls.selectedSection
        unreadChatCount = controls.unreadChatCount
        openSearch = controls.openSearch
    }
    
    var body: some View {
        filtersSection
        navigationSection
        
        if context.viewState.shouldShowSpaceFilters || openSearch != nil {
            additionalSection
        }
    }
    
    private var filtersSection: some View {
        Section {
            ForEach(Array(context.filtersState.activeFilters) + context.filtersState.availableFilters) { filter in
                ListRow(label: .plain(title: filter.localizedName),
                        kind: .toggle(filterBinding(for: filter)))
                    .accessibilityIdentifier(filter.chiichAccessibilityIdentifier)
            }
            
            if context.filtersState.isFiltering {
                ListRow(label: .action(title: L10n.screenRoomlistClearFilters,
                                       icon: \.close),
                        kind: .button { context.filtersState.clearFilters() })
                    .accessibilityIdentifier("chiich.settings.clearFilters")
            }
        } header: {
            Text(NSLocalizedString("chiich_chat_filters", tableName: "CHIICH", comment: "Chat filters section"))
                .compoundListSectionHeader()
                .accessibilityIdentifier("chiich.settings.filters")
        }
    }
    
    private var navigationSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenHomeTabChats, icon: \.chat),
                    details: unreadChatCount() > 0 ? .counter(unreadChatCount()) : nil,
                    kind: .selection(isSelected: selectedSection == .chats) {
                        selectedSection = .chats
                    })
                    .accessibilityAddTraits(selectedSection == .chats ? .isSelected : [])
                    .accessibilityIdentifier("chiich.settings.section.chats")
            
            ListRow(label: .default(title: L10n.screenHomeTabSpaces, icon: \.space),
                    kind: .selection(isSelected: selectedSection == .spaces) {
                        selectedSection = .spaces
                    })
                    .accessibilityAddTraits(selectedSection == .spaces ? .isSelected : [])
                    .accessibilityIdentifier("chiich.settings.section.spaces")
        }
    }
    
    private var additionalSection: some View {
        Section {
            if let openSearch {
                ListRow(label: .default(title: L10n.actionSearch, icon: \.search),
                        kind: .navigationLink { openSearch() })
                    .accessibilityIdentifier("chiich.settings.search")
            }
            
            if context.viewState.shouldShowSpaceFilters {
                ListRow(label: .default(title: L10n.screenRoomlistYourSpaces,
                                        description: context.viewState.selectedSpaceFilter?.room.name,
                                        icon: \.filter),
                        kind: .navigationLink { context.send(viewAction: .spaceFilters) })
                    .accessibilityIdentifier("chiich.settings.spaceFilter")
            }
            
            if context.viewState.selectedSpaceFilter != nil {
                ListRow(label: .action(title: NSLocalizedString("chiich_clear_space_filter", tableName: "CHIICH", comment: "Clear the selected space filter"),
                                       icon: \.close),
                        kind: .button { context.send(viewAction: .clearSpaceFilter) })
                    .accessibilityIdentifier("chiich.settings.clearSpaceFilter")
            }
        } header: {
            Text(NSLocalizedString("chiich_more_controls", tableName: "CHIICH", comment: "Additional native controls section"))
                .compoundListSectionHeader()
        }
    }
    
    private func filterBinding(for filter: RoomListFilter) -> Binding<Bool> {
        Binding(get: { context.filtersState.isFilterActive(filter) },
                set: { isEnabled in
                    if isEnabled {
                        context.filtersState.activateFilter(filter)
                    } else {
                        context.filtersState.deactivateFilter(filter)
                    }
                })
    }
}

extension View {
    @ViewBuilder
    func chiichHomeControlsPresentation(_ controls: CHIICHHomeControlsContext?) -> some View {
        if let controls {
            modifier(CHIICHHomeControlsPresentation(context: controls.homeContext))
        } else {
            self
        }
    }
}

/// Keep one presenter on the Settings form, outside its lazily materialised sections.
private struct CHIICHHomeControlsPresentation: ViewModifier {
    @ObservedObject var context: HomeScreenViewModel.Context
    
    func body(content: Content) -> some View {
        content.sheet(item: $context.spaceFiltersViewModel) { viewModel in
            ChatsSpaceFiltersScreen(context: viewModel.context)
        }
    }
}

private extension RoomListFilter {
    var chiichAccessibilityIdentifier: String {
        let name = switch self {
        case .unreads: "unreads"
        case .mentions: "mentions"
        case .favourites: "favourites"
        case .people: "people"
        case .rooms: "rooms"
        case .invites: "invites"
        case .lowPriority: "lowPriority"
        }
        return "chiich.settings.filter.\(name)"
    }
}
