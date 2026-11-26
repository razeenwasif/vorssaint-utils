// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Pitch-black Obsidian + Stratus electric-indigo aesthetic shared with Baryon.
enum StratusTheme {
    static let canvas = Color(red: 0.020, green: 0.020, blue: 0.027)          // #050507
    static let sidebarBg = Color(red: 0.031, green: 0.032, blue: 0.043)       // #08080b
    static let cardBg = Color(red: 0.047, green: 0.050, blue: 0.067)          // #0c0d11
    static let cardBgElevated = Color(red: 0.063, green: 0.067, blue: 0.088)  // #101116
    static let hairline = Color.white.opacity(0.075)
    static let hairlineStrong = Color.white.opacity(0.14)
    static let accent = Color(red: 0.243, green: 0.353, blue: 0.925)          // #3e5aec
    static let accentSoft = Color(red: 0.478, green: 0.537, blue: 1.000)      // #7a89ff
    static let orange = Color(red: 0.910, green: 0.510, blue: 0.333)          // #e88255
    static let purple = Color(red: 0.478, green: 0.537, blue: 1.000)          // #7a89ff
    static let cyan = Color(red: 0.294, green: 0.765, blue: 0.969)            // #4bc3f7
    static let mint = Color(red: 0.280, green: 0.860, blue: 0.680)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.56)
    static let textMuted = Color.white.opacity(0.38)
    static let nsCanvas = NSColor(srgbRed: 0.020, green: 0.020, blue: 0.027, alpha: 1.0)
}

/// Hairline-bordered obsidian card with a subtle top specular sheen.
struct StratusCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(StratusTheme.cardBg)
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.045), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(StratusTheme.hairline, lineWidth: 0.75)
            }
    }
}
