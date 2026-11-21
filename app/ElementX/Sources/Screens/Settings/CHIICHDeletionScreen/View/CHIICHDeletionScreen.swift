// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Compound
import SwiftUI

struct CHIICHDeletionScreen: View {
    @Bindable var context: CHIICHDeletionScreenViewModel.Context

    var body: some View {
        Form {
            if let error = context.viewState.error {
                Section {
                    Text(CHIICHDeletionStrings.message(for: error))
                        .foregroundStyle(.compound.textCriticalPrimary)
                        .accessibilityIdentifier("chiich.deletion.error")
                }
            }
            switch context.viewState.mode {
            case .entry:
                deletionEntry
            case .authentication:
                authentication
            case .success:
                Section { CHIICHDeletionNoticeView() }
            case .unavailable:
                EmptyView()
            }
            if context.viewState.isWorking {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("chiich.deletion.progress")
            }
        }
        .compoundList()
        .navigationTitle(CHIICHDeletionStrings.text("title"))
        .navigationBarBackButtonHidden(context.viewState.isWorking)
        .interactiveDismissDisabled(context.viewState.isWorking)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(context.viewState.mode == .success ? L10n.actionDone : L10n.actionCancel) {
                    context.send(viewAction: .close)
                }
                .disabled(context.viewState.isWorking)
                .accessibilityIdentifier("chiich.deletion.close")
            }
        }
        .confirmationDialog(CHIICHDeletionStrings.text("confirm_title"), isPresented: $context.confirmationShown, titleVisibility: .visible) {
            Button(CHIICHDeletionStrings.text("delete"), role: .destructive) { context.send(viewAction: .confirmDeletion) }
            Button(L10n.actionCancel, role: .cancel) { }
        } message: { Text(CHIICHDeletionStrings.text("warning")) }
        .sheet(item: $context.browser, onDismiss: { context.send(viewAction: .browserSheetDismissed) }) { presentation in
            VStack(spacing: 0) {
                CHIICHPasswordSSOBrowser(presentation: presentation) { nonce in
                    context.send(viewAction: .browserReturned(nonce))
                }
                Divider()
                finishSSOButton
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .privacySensitive()
        .accessibilityIdentifier("chiich.deletion.screen")
    }

    private var finishSSOButton: some View {
        Button(CHIICHDeletionStrings.text("finish_sso"), role: .destructive) {
            context.send(viewAction: .confirmSSO)
        }
        .disabled(context.viewState.isWorking)
        .accessibilityIdentifier("chiich.deletion.verifySSO")
    }

    private var deletionEntry: some View {
        Section {
            Text(CHIICHDeletionStrings.text("warning"))
            Button(CHIICHDeletionStrings.text("delete"), role: .destructive) { context.send(viewAction: .requestDeletion) }
                .accessibilityIdentifier("chiich.deletion.begin")
        }
        .disabled(context.viewState.isWorking)
    }

    @ViewBuilder
    private var authentication: some View {
        if let challenge = context.viewState.challenge {
            if challenge.availableStages.contains(.sso) {
                Section {
                    if context.viewState.returnedBrowserNonce != nil {
                        finishSSOButton
                    }
                    Button(CHIICHPasswordStrings.text("open_sso")) { context.send(viewAction: .openSSO) }
                        .accessibilityIdentifier("chiich.deletion.sso")
                } footer: {
                    Text(CHIICHDeletionStrings.text("sso_hint"))
                        .compoundListSectionFooter()
                }
                .disabled(context.viewState.isWorking)
            }
            if challenge.availableStages.contains(.password) {
                Section {
                    ListRow(label: .plain(title: CHIICHPasswordStrings.text("current_password")), kind: .secureField(text: $context.currentPassword))
                        .textContentType(.password)
                        .accessibilityIdentifier("chiich.deletion.current")
                    Button(CHIICHPasswordStrings.text("confirm_password")) { context.send(viewAction: .submitPassword) }
                        .disabled(context.currentPassword.isEmpty)
                        .accessibilityIdentifier("chiich.deletion.confirmCurrent")
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
