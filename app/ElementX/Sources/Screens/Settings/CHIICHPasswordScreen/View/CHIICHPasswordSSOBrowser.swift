// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SafariServices
import SwiftUI

/// System-owned browser for the server's UIA fallback only. No JS bridge or access-token injection.
struct CHIICHPasswordSSOBrowser: UIViewControllerRepresentable {
    let presentation: CHIICHPasswordSSOPresentation
    let onReturn: (UUID) -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: presentation.url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(nonce: presentation.id, onReturn: onReturn)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let nonce: UUID
        private let onReturn: (UUID) -> Void

        init(nonce: UUID, onReturn: @escaping (UUID) -> Void) {
            self.nonce = nonce
            self.onReturn = onReturn
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            // Done is a return signal, never evidence of successful UIA.
            onReturn(nonce)
        }
    }
}
