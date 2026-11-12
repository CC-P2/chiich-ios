// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI

struct CHIICHReceiverAILanguagePicker: View {
    let service: CHIICHReceiverAIService
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var languages: [String] {
        let codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + [service.language])
        return codes.filter {
            CHIICHReceiverAILanguage.validTarget($0)
                && (query.isEmpty || title($0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query))
        }.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }

    var body: some View {
        ElementNavigationStack {
            List(languages, id: \.self) { code in
                Button {
                    service.setLanguage(code)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(title(code))
                            .foregroundStyle(.compound.textPrimary)
                        Spacer()
                        if service.language == code {
                            Image(systemName: "checkmark")
                                .foregroundStyle(CHIICHTheme.accent)
                        }
                    }
                }
                .accessibilityIdentifier("chiich.receiverAI.language.\(code)")
            }
            .searchable(text: $query)
            .navigationTitle(L10n.screenChiichReceiverAiLanguage)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) { dismiss() }
                }
            }
        }
    }

    private func title(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

struct ChiichReceiverAILanguages_Previews: PreviewProvider, TestablePreview {
    static let service = CHIICHReceiverAIService(accountID: "@preview:chat.chiich.one",
                                                request: { _, _ in .failure(.unavailable) },
                                                loadAudio: { _, _ in .failure(.unavailable) },
                                                sessionIsCurrent: { false },
                                                claims: nil,
                                                preferences: UserDefaults(suiteName: "CHIICHReceiverAILanguagePreview")!)

    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        CHIICHReceiverAILanguagePicker(service: service)
            .previewDisplayName("Search translation languages")
        CHIICHReceiverAILanguagePicker(service: service)
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Graphite translation languages")
    }
}
