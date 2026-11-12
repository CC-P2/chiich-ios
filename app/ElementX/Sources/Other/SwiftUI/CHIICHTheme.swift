//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

enum CHIICHTheme {
    static let paper = Color(paperUI)
    static let ink = Color(inkUI)
    static let muted = Color(mutedUI)
    static let line = Color(lineUI)
    static let accent = Color(accentUI)
    static let send = Color(sendUI)
    static let strip = Color(stripUI)
    static let incomingBubble = Color(adaptive(light: 0xF0F2F5, dark: 0x303338))
    static let outgoingBubble = Color(adaptive(light: 0xE9F3FF, dark: 0x294349))
    
    static let paperUI = adaptive(light: 0xFFFFFF, dark: 0x202225)
    static let inkUI = adaptive(light: 0x111314, dark: 0xF5F5F6)
    static let mutedUI = adaptive(light: 0x86888D, dark: 0xA5A7AD, highContrastLight: 0x51545A, highContrastDark: 0xD4D6DC)
    static let lineUI = adaptive(light: 0xECECEF, dark: 0x33363B)
    static let accentUI = adaptive(light: 0x0786E8, dark: 0x55D8E2)
    static let sendUI = adaptive(light: 0x087CF0, dark: 0x087CF0)
    static let stripUI = adaptive(light: 0xF5F6F8, dark: 0x292C30)
    
    private nonisolated static func adaptive(light: UInt32, dark: UInt32,
                                             highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) -> UIColor {
        UIColor { traits in
            let value: UInt32
            if traits.userInterfaceStyle == .dark {
                value = traits.accessibilityContrast == .high ? highContrastDark ?? dark : dark
            } else {
                value = traits.accessibilityContrast == .high ? highContrastLight ?? light : light
            }
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

struct CHIICHCompoundHook: CompoundHookProtocol {
    func override(colors: CompoundColors, uiColors: CompoundUIColors) {
        colors.override(\.bgCanvasDefault, with: CHIICHTheme.paper)
        colors.override(\.bgCanvasDefaultLevel1, with: CHIICHTheme.paper)
        colors.override(\.bgSubtlePrimary, with: CHIICHTheme.strip)
        colors.override(\.bgSubtleSecondary, with: CHIICHTheme.strip)
        colors.override(\.textPrimary, with: CHIICHTheme.ink)
        colors.override(\.textSecondary, with: CHIICHTheme.muted)
        colors.override(\.textActionAccent, with: CHIICHTheme.accent)
        colors.override(\.iconPrimary, with: CHIICHTheme.ink)
        colors.override(\.iconSecondary, with: CHIICHTheme.muted)
        colors.override(\.iconAccentPrimary, with: CHIICHTheme.accent)
        colors.override(\.iconAccentTertiary, with: CHIICHTheme.accent)
        colors.override(\.bgAccentRest, with: CHIICHTheme.send)
        colors.override(\.borderDisabled, with: CHIICHTheme.line)
        uiColors.override(\.bgCanvasDefault, with: CHIICHTheme.paperUI)
        uiColors.override(\.bgCanvasDefaultLevel1, with: CHIICHTheme.paperUI)
        uiColors.override(\.bgSubtlePrimary, with: CHIICHTheme.stripUI)
        uiColors.override(\.bgSubtleSecondary, with: CHIICHTheme.stripUI)
        uiColors.override(\.textPrimary, with: CHIICHTheme.inkUI)
        uiColors.override(\.textSecondary, with: CHIICHTheme.mutedUI)
        uiColors.override(\.textActionAccent, with: CHIICHTheme.accentUI)
        uiColors.override(\.iconPrimary, with: CHIICHTheme.inkUI)
        uiColors.override(\.iconSecondary, with: CHIICHTheme.mutedUI)
        uiColors.override(\.iconAccentPrimary, with: CHIICHTheme.accentUI)
        uiColors.override(\.iconAccentTertiary, with: CHIICHTheme.accentUI)
        uiColors.override(\.bgAccentRest, with: CHIICHTheme.sendUI)
        uiColors.override(\.borderDisabled, with: CHIICHTheme.lineUI)
    }
}

struct CHIICHBrandMark: View {
    var isActive = true
    
    var body: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .grayscale(isActive ? 0 : 1)
            .opacity(isActive ? 1 : 0.75)
            .accessibilityHidden(true)
    }
}

struct CHIICHPlannerStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        if let plannerURL = URL(string: "https://wplus.pro") {
            Link(destination: plannerURL) {
                HStack(spacing: 0) {
                    Image("images/chiich-wplus")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 30)
                        .blendMode(colorScheme == .dark ? .screen : .normal)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(LinearGradient(colors: [CHIICHTheme.strip, CHIICHTheme.paper, CHIICHTheme.strip], startPoint: .leading, endPoint: .trailing))
                .compositingGroup()
                .overlay(alignment: .top) { CHIICHTheme.line.frame(height: 0.5) }
                .overlay(alignment: .bottom) { CHIICHTheme.line.frame(height: 0.5) }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(NSLocalizedString("chiich_wplus_open_planner", tableName: "CHIICH", comment: "W+ planner shortcut"))
        }
    }
}
