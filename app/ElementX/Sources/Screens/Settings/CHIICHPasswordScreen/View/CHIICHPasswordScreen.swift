// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Compound
import SwiftUI

struct CHIICHPasswordScreen: View {
    @Bindable var context: CHIICHPasswordScreenViewModel.Context

    var body: some View {
        Form {
            if let error = context.viewState.error {
                Section {
                    Text(CHIICHPasswordStrings.message(for: error))
                        .foregroundStyle(.compound.textCriticalPrimary)
                        .accessibilityIdentifier("chiich.password.error")
                }
            }
            switch context.viewState.mode {
            case .loading:
                ProgressView()
            case .entry:
                passwordEntry
            case .authentication:
                authentication
            case .success:
                Section {
                    Label(CHIICHPasswordStrings.text("success"), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("chiich.password.success")
                    Text(CHIICHPasswordStrings.text("sessions_kept"))
                        .foregroundStyle(.compound.textSecondary)
                }
            case .unavailable:
                EmptyView()
            }
            if context.viewState.isWorking {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("chiich.password.progress")
            }
        }
        .compoundList()
        .navigationTitle(CHIICHPasswordStrings.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(context.viewState.mode == .success ? L10n.actionDone : L10n.actionCancel) {
                    context.send(viewAction: .close)
                }
                .accessibilityIdentifier("chiich.password.close")
            }
        }
        .sheet(item: $context.browser, onDismiss: { context.send(viewAction: .browserSheetDismissed) }) { presentation in
            CHIICHPasswordSSOBrowser(presentation: presentation) { nonce in
                context.send(viewAction: .browserReturned(nonce))
            }
            .ignoresSafeArea()
        }
        .privacySensitive()
        .accessibilityIdentifier("chiich.password.screen")
    }

    private var passwordEntry: some View {
        Section {
            ListRow(label: .plain(title: CHIICHPasswordStrings.text("new_password")), kind: .secureField(text: $context.newPassword))
                .textContentType(.newPassword)
                .accessibilityIdentifier("chiich.password.new")
            ListRow(label: .plain(title: CHIICHPasswordStrings.text("confirmation")), kind: .secureField(text: $context.confirmation))
                .textContentType(.newPassword)
                .accessibilityIdentifier("chiich.password.confirmation")
            Button(CHIICHPasswordStrings.text("save")) { context.send(viewAction: .save) }
                .disabled(!context.viewState.canSubmitNewPassword)
                .accessibilityIdentifier("chiich.password.save")
        } footer: {
            Text(CHIICHPasswordStrings.text("first_password_hint"))
                .compoundListSectionFooter()
        }
        .disabled(context.viewState.isWorking)
    }

    @ViewBuilder
    private var authentication: some View {
        if let challenge = context.viewState.challenge {
            if challenge.availableStages.contains(.sso) {
                Section {
                    Button(CHIICHPasswordStrings.text("open_sso")) { context.send(viewAction: .openSSO) }
                        .accessibilityIdentifier("chiich.password.sso")
                    if context.viewState.returnedBrowserNonce != nil {
                        Button(CHIICHPasswordStrings.text("verify_sso")) { context.send(viewAction: .confirmSSO) }
                            .accessibilityIdentifier("chiich.password.verifySSO")
                    }
                } footer: {
                    Text(CHIICHPasswordStrings.text("sso_hint"))
                        .compoundListSectionFooter()
                }
                .disabled(context.viewState.isWorking)
            }
            if challenge.availableStages.contains(.password) {
                Section {
                    ListRow(label: .plain(title: CHIICHPasswordStrings.text("current_password")), kind: .secureField(text: $context.currentPassword))
                        .textContentType(.password)
                        .accessibilityIdentifier("chiich.password.current")
                    Button(CHIICHPasswordStrings.text("confirm_password")) { context.send(viewAction: .submitPassword) }
                        .disabled(context.currentPassword.isEmpty)
                        .accessibilityIdentifier("chiich.password.confirmCurrent")
                }
                .disabled(context.viewState.isWorking)
            }
            if challenge.isComplete {
                Button(L10n.actionContinue) { context.send(viewAction: .finishCompletedChallenge) }
                    .disabled(context.viewState.isWorking)
            }
        }
    }
}
