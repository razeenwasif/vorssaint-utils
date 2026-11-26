// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Animated electric-blue tip aura & bottom lip glow shown when the pointer
/// hovers over the bottom-center tip of the closed Dynamic Island.
struct NotchTipGlowBar: View {
    let active: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if active {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.243, green: 0.353, blue: 0.925),
                                Color(red: 0.294, green: 0.765, blue: 0.969),
                                Color(red: 0.478, green: 0.537, blue: 1.000),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: pulse && !reduceMotion ? 58 : 42, height: 2.5)
                    .shadow(color: Color(red: 0.243, green: 0.353, blue: 0.925).opacity(pulse ? 0.95 : 0.65),
                            radius: pulse ? 9 : 5, y: 0)
                    .shadow(color: Color(red: 0.294, green: 0.765, blue: 0.969).opacity(0.65),
                            radius: 5, y: -1)
                    .padding(.bottom, 1.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.75)))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                    .onDisappear { pulse = false }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FairyTipAction: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let shortcut: String
}

/// Compact Stratus-styled icon strip revealed on clicking the glowing Notch tip,
/// surfacing Fairy's screen/quick-ask shortcuts with hover key hints.
struct NotchFairyTipActionsView: View {
    @ObservedObject var service: NotchService
    @State private var hovered: FairyTipAction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let actions: [FairyTipAction] = [
        FairyTipAction(id: "area", symbol: "rectangle.dashed", title: "Drag over what to ask", shortcut: "⌃⌥A"),
        FairyTipAction(id: "box", symbol: "sparkles", title: "Ask Fairy", shortcut: "⌥⌘"),
        FairyTipAction(id: "talk", symbol: "waveform", title: "Talk & circle / Explain", shortcut: "⌃⌥"),
        FairyTipAction(id: "quiz", symbol: "lightbulb.max", title: "Quiz hints", shortcut: "Quiz"),
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ForEach(Self.actions) { item in
                    let isHovered = hovered?.id == item.id
                    Button {
                        service.dismissTipActions()
                        BaryonBridgeService.shared.sendQuickAction(item.id)
                    } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isHovered ? Color.white : Color.white.opacity(0.84))
                            .frame(width: 36, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isHovered
                                          ? Color(red: 0.243, green: 0.353, blue: 0.925).opacity(0.30)
                                          : Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isHovered
                                            ? Color(red: 0.478, green: 0.537, blue: 1.0).opacity(0.85)
                                            : Color.white.opacity(0.08),
                                        lineWidth: isHovered ? 1 : 0.5
                                    )
                            )
                            .shadow(color: isHovered ? Color(red: 0.243, green: 0.353, blue: 0.925).opacity(0.55) : .clear, radius: 6)
                            .scaleEffect(isHovered && !reduceMotion ? 1.07 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { over in
                        hovered = over ? item : (hovered?.id == item.id ? nil : hovered)
                    }
                    .accessibilityLabel("\(item.title) (\(item.shortcut))")
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78), value: hovered?.id)

            HStack(spacing: 6) {
                if let hovered {
                    Text(hovered.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .lineLimit(1)
                    Text(hovered.shortcut)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.478, green: 0.537, blue: 1.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.243, green: 0.353, blue: 0.925).opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color(red: 0.478, green: 0.537, blue: 1.0).opacity(0.35), lineWidth: 0.5)
                        )
                } else {
                    Text("Hover an icon · Drag notch down for Fairy")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(1)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 16)
        .padding(.top, service.geometry.safeContentTop + 4)
        .padding(.bottom, 10)
        .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .center)
    }
}
