//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChiichNativeExperience_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        home
            .environment(\.colorScheme, .light)
            .previewDisplayName("Loaded chats light")
        home
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Loaded chats graphite")
        room
            .environment(\.colorScheme, .light)
            .previewDisplayName("Conversation light")
        room
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Conversation graphite")
    }
    
    private static var home: some View {
        ElementNavigationStack {
            HomeScreen(context: HomeScreen_Previews.loadedViewModel.context)
        }
        .snapshotPreferences(expect: HomeScreen_Previews.loadedViewModel.context.$viewState.map { $0.roomListMode == .rooms })
    }
    
    private static var room: some View {
        ElementNavigationStack {
            RoomScreen(context: RoomScreen_Previews.viewModels.room.context,
                       timelineContext: RoomScreen_Previews.viewModels.timeline.context,
                       composerToolbar: ComposerToolbar(context: RoomScreen_Previews.composerViewModel.context))
        }
    }
}
