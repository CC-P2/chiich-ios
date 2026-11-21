// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Compound
import SwiftUI

struct CHIICHDeletionNoticeView: View {
    @AppStorage(CHIICHDeletionNotice.key, store: CHIICHDeletionNotice.defaults) private var hasReceipt = false
    var body: some View {
        if hasReceipt {
            VStack(alignment: .leading, spacing: 12) {
                Text(CHIICHDeletionStrings.text("success")).font(.headline)
                Text(CHIICHDeletionStrings.text("history_notice"))
                Text(CHIICHDeletionStrings.text("apple_notice"))
                Link(CHIICHDeletionStrings.text("apple_help"), destination: URL(string: "https://support.apple.com/102571")!)
                Button(L10n.actionDone) { hasReceipt = false }
            }
            .font(.compound.bodySM)
            .padding()
            .accessibilityIdentifier("chiich.deletion.receipt")
        }
    }
}
