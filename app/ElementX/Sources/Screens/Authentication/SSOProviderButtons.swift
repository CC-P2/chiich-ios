//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct SSOProviderButtons: View {
    let action: (SSOIdentityProvider) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Button { action(.apple) } label: {
                Label(NSLocalizedString("chiich_sso_apple", tableName: "CHIICHAuthentication", comment: "Apple SSO button"), systemImage: "apple.logo")
            }
            .buttonStyle(.compound(.primary))
            .accessibilityIdentifier("chiich.login.apple")
            
            Button { action(.google) } label: {
                Text(NSLocalizedString("chiich_sso_google", tableName: "CHIICHAuthentication", comment: "Google SSO button"))
            }
            .buttonStyle(.compound(.secondary))
            .accessibilityIdentifier("chiich.login.google")
        }
    }
}
