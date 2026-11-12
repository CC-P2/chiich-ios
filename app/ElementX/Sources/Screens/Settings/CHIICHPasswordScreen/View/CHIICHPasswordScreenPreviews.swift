// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI

struct CHIICHPasswordScreen_Previews: PreviewProvider, TestablePreview {
    static let entry: CHIICHPasswordScreenViewModel = {
        let model = CHIICHPasswordScreenViewModel(service: nil)
        model.state.mode = .entry
        return model
    }()

    static let sso: CHIICHPasswordScreenViewModel = {
        let model = CHIICHPasswordScreenViewModel(service: nil)
        model.state.mode = .authentication
        model.state.challenge = .init(session: "preview-only", flows: [.init(stages: ["m.login.sso"])], completed: [], errcode: nil)
        model.state.returnedBrowserNonce = UUID()
        return model
    }()

    static let success: CHIICHPasswordScreenViewModel = {
        let model = CHIICHPasswordScreenViewModel(service: nil)
        model.state.mode = .success
        return model
    }()

    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        ElementNavigationStack { CHIICHPasswordScreen(context: entry.context) }
            .previewDisplayName("First or new password")
        ElementNavigationStack { CHIICHPasswordScreen(context: entry.context) }
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Graphite password")
        ElementNavigationStack { CHIICHPasswordScreen(context: sso.context) }
            .previewDisplayName("Return from SSO confirmation")
        ElementNavigationStack { CHIICHPasswordScreen(context: success.context) }
            .previewDisplayName("Server confirmed success")
    }
}
