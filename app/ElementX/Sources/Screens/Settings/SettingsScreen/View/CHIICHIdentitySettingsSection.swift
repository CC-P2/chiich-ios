// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Compound
import SwiftUI

/// The existing profile and chat controls remain separate, sharing the same native Settings form.
struct CHIICHIdentitySettingsSection: View {
    @Bindable var model: CHIICHIdentitySettingsModel
    @FocusState private var usernameFocused: Bool

    var body: some View {
        Section {
            if model.isEditing {
                editor
            } else {
                ListRow(label: .default(title: L10n.screenChiichIdentityUsername,
                                        description: model.username?.value ?? L10n.screenChiichIdentityChooseUsername,
                                        icon: \.userProfile),
                        details: .isWaiting(model.isBusy),
                        kind: .button {
                            model.beginEditing()
                            usernameFocused = true
                        })
                        .disabled(!model.canBeginEditing)
                        .accessibilityIdentifier("chiich.identity.username")
            }

            if let shareURL = model.shareURL {
                ListRow(label: .default(title: L10n.screenChiichIdentityMyLink,
                                        description: model.username?.displayLink,
                                        icon: \.link),
                        kind: .button { model.copyInvitation() })
                    .accessibilityHint(L10n.actionCopyLink)
                    .accessibilityIdentifier("chiich.identity.link")

                HStack(spacing: 12) {
                    Button { model.copyInvitation() } label: {
                        Label(L10n.screenChiichIdentityInviteFriend, icon: \.userAdd)
                            .font(.compound.bodyLG)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("chiich.identity.invite")
                    Spacer(minLength: 12)
                    ShareLink(item: shareURL) {
                        CompoundIcon(\.shareIos)
                            .padding(8)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.actionShare)
                    .accessibilityIdentifier("chiich.identity.share")
                }
                .foregroundStyle(CHIICHTheme.accent)
            }

            if model.error != nil || model.needsReload {
                ListRow(label: .action(title: L10n.screenChiichIdentityRefresh, icon: \.restart),
                        details: .isWaiting(model.isBusy),
                        kind: .button { Task { await model.reload() } })
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("chiich.identity.refresh")
            }
        } footer: {
            if let error = model.error {
                Text(CHIICHIdentityStrings.message(for: error))
                    .foregroundStyle(.compound.textCriticalPrimary)
                    .compoundListSectionFooter()
                    .accessibilityIdentifier("chiich.identity.error")
            } else if model.isEditing, !model.draft.isEmpty, !model.isDraftValid {
                Text(L10n.screenChiichIdentityInvalidUsername)
                    .foregroundStyle(.compound.textCriticalPrimary)
                    .compoundListSectionFooter()
            } else if model.isEditing {
                Text(L10n.screenChiichIdentityUsernameHint)
                    .compoundListSectionFooter()
            }
        }
        .tint(CHIICHTheme.accent)
        .task { await model.loadIfNeeded() }
    }

    private var editor: some View {
        Group {
            ListRow(label: .plain(title: L10n.screenChiichIdentityUsername),
                    kind: .textField(text: $model.draft))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($usernameFocused)
                .disabled(model.isBusy)
                .submitLabel(.done)
                .onSubmit { Task { await model.save() } }
                .accessibilityIdentifier("chiich.identity.usernameEditor")

            HStack(spacing: 12) {
                Button(L10n.actionCancel) {
                    model.cancelEditing()
                    usernameFocused = false
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("chiich.identity.cancel")
                Spacer()
                if model.isBusy { ProgressView() }
                Button(L10n.actionSave) {
                    usernameFocused = false
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("chiich.identity.save")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(CHIICHTheme.accent)
        }
    }
}
