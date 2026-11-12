// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Compound
import SwiftUI

struct CHIICHIdentitySettings_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)

        preview(model: .preview())
            .previewDisplayName("Profile link")
        preview(model: .preview(editing: true))
            .previewDisplayName("Edit username")
        preview(model: .preview(loading: true))
            .previewDisplayName("Loading username")
        preview(model: .preview(editing: true, failure: .conflict))
            .previewDisplayName("Name conflict")
        preview(model: .preview())
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Graphite profile link")
        preview(model: .preview(hasChosenUsername: false))
            .previewDisplayName("Choose first username")
        preview(model: .preview(editing: true, hasChosenUsername: false))
            .previewDisplayName("First username editor")
        preview(model: .preview(hasChosenUsername: false))
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Graphite first username")
    }

    private static func preview(model: CHIICHIdentitySettingsModel) -> some View {
        ElementNavigationStack {
            Form {
                Section {
                    ListRow(label: .default(title: "Ivan",
                                            description: model.username?.value ?? L10n.screenChiichIdentityChooseUsername,
                                            icon: \.userProfile), kind: .label)
                }
                CHIICHIdentitySettingsSection(model: model)
            }
            .compoundList()
        }
    }
}
