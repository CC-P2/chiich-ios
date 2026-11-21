// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI

struct CHIICHRegistrationScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var invitation = ""
    @State private var message: String?
    @State private var submission: Task<Void, Never>?

    let onCreated: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.commonUsername, text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField(L10n.commonPassword, text: $password)
                        .textContentType(.newPassword)
                    TextField(CHIICHRegistration.text("invite"), text: $invitation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(CHIICHRegistration.text("invite_hint"))
                }
                if let message {
                    Text(CHIICHRegistration.text(message))
                        .accessibilityIdentifier("chiich.registration.message")
                }
                Button(CHIICHRegistration.text("submit"), action: submit)
                    .disabled(username.isEmpty || password.isEmpty)
                if submission != nil { ProgressView(L10n.commonLoading) }
            }
            .disabled(submission != nil)
            .navigationTitle(CHIICHRegistration.text("submit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) { dismiss() }.disabled(submission != nil)
                }
            }
        }
        .interactiveDismissDisabled(submission != nil)
        .onDisappear { submission?.cancel() }
    }

    private func submit() {
        guard submission == nil else { return }
        message = nil
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { message = "invalid"; return }
        submission = Task {
            defer { submission = nil }
            let result = await CHIICHRegistration.create(username: name, password: password, invitation: token)
            guard !Task.isCancelled else { return }
            switch result {
            case .created(let userID): onCreated(userID, password)
            case .rejected(let key): message = key
            case .challenge: message = "unsupported"
            }
        }
    }
}
