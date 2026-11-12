//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

@Observable final class CHIICHTimelineViewport {
    var height: CGFloat = 0
}

extension EnvironmentValues {
    @Entry var chiichTimelineViewport: CHIICHTimelineViewport?
}

nonisolated struct CHIICHMessageDisclosureMetrics {
    let needsDisclosure: Bool
    let collapsedContentHeight: CGFloat
    
    init(contentHeight: CGFloat, viewportHeight: CGFloat, reservedHeight: CGFloat, controlHeight: CGFloat) {
        let limit = max(0, viewportHeight / 2)
        needsDisclosure = viewportHeight > 0 && contentHeight + max(0, reservedHeight) > limit
        collapsedContentHeight = max(0, limit - max(0, reservedHeight) - max(0, controlHeight))
    }
}

struct CHIICHMessageDisclosure<Content: View>: View {
    @Environment(\.chiichTimelineViewport) private var viewport
    let reservedHeight: CGFloat
    @Binding var renderedHeight: CGFloat
    @ViewBuilder let content: () -> Content
    
    @State private var naturalHeight: CGFloat = 0
    @State private var controlHeight: CGFloat = 44
    @State private var isExpanded = false
    
    private var metrics: CHIICHMessageDisclosureMetrics {
        .init(contentHeight: naturalHeight, viewportHeight: viewport?.height ?? 0,
              reservedHeight: reservedHeight, controlHeight: controlHeight)
    }
    
    private var controlTitle: String {
        NSLocalizedString(isExpanded ? "chiich_action_collapse_message" : "chiich_action_expand_message", tableName: "CHIICH", comment: "Message disclosure")
    }
    
    private var accessibilityTitle: String {
        NSLocalizedString(isExpanded ? "chiich_a11y_collapse_message" : "chiich_a11y_expand_message", tableName: "CHIICH", comment: "Message disclosure accessibility action")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Measure the single native content instance before clipping: players and links retain their state.
            content()
                .fixedSize(horizontal: false, vertical: true)
                .readHeight($naturalHeight)
                .frame(maxHeight: metrics.needsDisclosure && !isExpanded ? metrics.collapsedContentHeight : nil, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
            
            if metrics.needsDisclosure {
                Button { isExpanded.toggle() } label: {
                    Text(controlTitle)
                        .font(.compound.bodyMDSemibold)
                        .foregroundStyle(CHIICHTheme.accent)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle)
                .readHeight($controlHeight)
            }
        }
        .readHeight($renderedHeight)
        .accessibilityActions {
            if metrics.needsDisclosure {
                Button(accessibilityTitle) { isExpanded.toggle() }
            }
        }
    }
}

struct ChiichMessageDisclosure_Previews: PreviewProvider, TestablePreview {
    static let viewport: CHIICHTimelineViewport = {
        let viewport = CHIICHTimelineViewport()
        viewport.height = 600
        return viewport
    }()
    
    static var previews: some View {
        let _ = CHIICHCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        examples
            .previewDisplayName("Short and long messages")
        examples
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Graphite messages")
        examples
            .environment(\.dynamicTypeSize, .accessibility3)
            .previewDisplayName("Accessible long messages")
    }
    
    private static var examples: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CHIICHMessageDisclosure(reservedHeight: 40, renderedHeight: .constant(0)) {
                    Text("Short message stays visible.")
                }
                CHIICHMessageDisclosure(reservedHeight: 40, renderedHeight: .constant(0)) {
                    Text(String(repeating: "A long message or transcript remains complete and can be expanded. ", count: 30))
                }
                CHIICHMessageDisclosure(reservedHeight: 40, renderedHeight: .constant(0)) {
                    Rectangle().fill(CHIICHTheme.outgoingBubble).frame(width: 240, height: 420)
                        .accessibilityLabel("Media fixture")
                }
            }
            .font(.compound.bodyLG)
            .padding()
        }
        .background(CHIICHTheme.paper)
        .environment(\.chiichTimelineViewport, viewport)
    }
}
