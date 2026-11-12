// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Compound
import SwiftUI

struct CHIICHReceiverAIControl: View {
    let service: CHIICHReceiverAIService?
    private enum Sheet: String, Identifiable {
        case consent, language
        var id: Self { self }
    }

    @State private var activeSheet: Sheet?
    @State private var showingConsent = false
    
    var body: some View {
        Menu {
            if let service {
                Button(L10n.screenChiichAiConsentManage) { showingConsent = true }
                if service.consentDecision == .granted {
                    Button {
                        activeSheet = .language
                    } label: {
                        Text("\(L10n.screenChiichReceiverAiLanguage): \(Locale.current.localizedString(forLanguageCode: service.language) ?? service.language)")
                    }
                }
                Text(statusLabel)
                if service.availability == .unavailable || service.preferenceSyncFailed {
                    Button(L10n.actionRetry) { Task { await service.refreshConnection() } }
                }
            } else {
                Text(L10n.screenChiichReceiverAiUnavailable)
            }
        } label: {
            CHIICHBrandMark(isActive: service?.isActive == true)
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel(L10n.screenChiichReceiverAiTitle)
        .accessibilityValue(statusLabel)
        .accessibilityIdentifier("chiich.receiverAI.control")
        .task {
            guard let service else { return }
            if await service.prepareAutomaticConsentPrompt(), !Task.isCancelled, activeSheet == nil, !showingConsent {
                showingConsent = true
            }
            await service.connectIfNeeded()
        }
        .fullScreenCover(isPresented: $showingConsent) {
            if let service { CHIICHReceiverAIConsentScreen(service: service) }
        }
        .sheet(item: $activeSheet) { sheet in
            if let service {
                switch sheet {
                case .consent: CHIICHReceiverAIConsentScreen(service: service)
                case .language: CHIICHReceiverAILanguagePicker(service: service)
                }
            }
        }
    }
    
    private var statusLabel: String {
        guard let service else { return L10n.screenChiichReceiverAiUnavailable }
        if service.preferenceSyncFailed {
            return L10n.screenChiichAiConsentSyncFailure
        }
        if !service.enabled {
            return L10n.screenChiichReceiverAiOff
        }
        if !service.preferencesReady {
            return L10n.screenChiichReceiverAiChecking
        }
        switch service.availability {
        case .idle, .checking: return L10n.screenChiichReceiverAiChecking
        case .ready: return L10n.screenChiichReceiverAiReady
        case .unavailable: return L10n.screenChiichReceiverAiUnavailable
        }
    }
}

struct CHIICHReceiverAIConsentScreen: View {
    let service: CHIICHReceiverAIService
    @Environment(\.dismiss) private var dismiss
    @State private var showingDetails = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    CHIICHConsentBrandMark()
                        .frame(width: 68, height: 52)
                        .accessibilityHidden(true)
                    Text(L10n.screenChiichAiConsentSummary)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if service.preferenceSyncFailed {
                        Text(L10n.screenChiichAiConsentSyncFailure)
                            .font(.callout)
                        Button(L10n.actionRetry) {
                            Task { await service.refreshConnection() }
                        }
                    }
                    if service.consentDecision == .granted {
                        choice(L10n.screenChiichAiConsentDisable, consent: false,
                               color: Color(red: 0.03, green: 0.49, blue: 0.94), identifier: "chiich.receiverAI.revoke")
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { choices }
                            VStack(spacing: 10) { choices }
                        }
                    }
                    Button { showingDetails = true } label: {
                        Text(L10n.screenChiichAiConsentDetails).underline()
                            .font(.body)
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(CHIICHTheme.accent)
                    .accessibilityIdentifier("chiich.receiverAI.details")
                    if service.consentDecision == .granted {
                        Button(L10n.actionClose) { dismiss() }
                    }
                }
                .foregroundStyle(CHIICHTheme.ink)
                .padding(24)
                .frame(maxWidth: 440)
                .background(CHIICHTheme.paper, in: RoundedRectangle(cornerRadius: 28))
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .defaultScrollAnchor(.center)
        }
        .presentationBackground(.clear)
        .sheet(isPresented: $showingDetails) {
            ElementNavigationStack {
                CHIICHReceiverAIConsentDetails()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.actionClose) { showingDetails = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder private var choices: some View {
        choice(L10n.screenChiichAiConsentNo, consent: false,
               color: Color(red: 0.03, green: 0.49, blue: 0.94), identifier: "chiich.receiverAI.decline")
        choice(L10n.screenChiichAiConsentYes, consent: true,
               color: Color(red: 0.0, green: 0.48, blue: 0.20), identifier: "chiich.receiverAI.grant")
    }

    private func choice(_ title: String, consent: Bool, color: Color, identifier: String) -> some View {
        Button {
            service.setConsent(consent)
            dismiss()
        } label: {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 12)
                .foregroundStyle(.white)
                .background(color, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// Owner's approved mark: concave blue sparkle between two navy capsules.
private struct CHIICHConsentBrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            HStack(spacing: 4) {
                Capsule().fill(Color(red: 0.04, green: 0.07, blue: 0.28)).frame(width: width * 0.11)
                CHIICHConsentSparkle().fill(Color(red: 0.02, green: 0.52, blue: 1))
                Capsule().fill(Color(red: 0.04, green: 0.07, blue: 0.28)).frame(width: width * 0.11)
            }
            .frame(width: width, height: height)
        }
    }
}

private struct CHIICHConsentSparkle: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let x = rect.midX, y = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: y), control: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: x, y: rect.maxY), control: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: y), control: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x, y: y))
        path.closeSubpath()
        return path
    }
}

// Full disclosure stays available inside the app before either choice.
// No new browser transition or provider request is introduced.
struct CHIICHReceiverAIConsentDetails: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.screenChiichAiConsentTransfer)
                Text(L10n.screenChiichAiConsentPeer)
                Text(L10n.screenChiichAiConsentControl)
                Link(L10n.commonPrivacyPolicy, destination: AppSettings.chiichPrivacyURL)
                    .foregroundStyle(CHIICHTheme.accent)
                    .accessibilityIdentifier("chiich.receiverAI.privacy")
            }
            .font(.compound.bodyMD)
            .foregroundStyle(.compound.textPrimary)
            .padding()
        }
        .navigationTitle(L10n.screenChiichAiConsentDetails)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CHIICHReceiverAICaption: View {
    @Environment(\.timelineContext) private var context
    let eventID: String?
    let sourceURL: String?
    let trailingReservedSize: CGSize
    
    var body: some View {
        if let context, let presentation = context.viewState.chiichReceiverAI?.presentation(roomID: context.viewState.roomID, eventID: eventID, originalFingerprint: CHIICHReceiverAIIdentity.hash(["audio", sourceURL ?? ""])) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.originalTranscript == presentation.text ? L10n.screenChiichReceiverAiTranscript : L10n.screenChiichReceiverAiTranslatedTranscript)
                    .font(.compound.bodyXS)
                    .foregroundStyle(.compound.textSecondary)
                FormattedBodyText(text: presentation.text, trailingReservedSize: trailingReservedSize, boostFontSize: false)
            }
            .accessibilityIdentifier("chiich.receiverAI.transcript")
        }
    }
}

struct CHIICHReceiverAIControl_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        CHIICHReceiverAIControl(service: nil)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}

struct CHIICHReceiverAIConsentScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        CHIICHReceiverAIConsentScreen(service: ChiichReceiverAILanguages_Previews.service)
            .previewDisplayName("AI consent")
        CHIICHReceiverAIConsentScreen(service: ChiichReceiverAILanguages_Previews.service)
            .environment(\.dynamicTypeSize, .accessibility2)
            .environment(\.colorScheme, .dark)
            .previewDisplayName("AI consent · large text")
    }
}
