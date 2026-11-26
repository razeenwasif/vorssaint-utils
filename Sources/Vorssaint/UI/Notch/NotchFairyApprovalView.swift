// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NotchFairyApprovalView: View {
    let approval: BaryonApproval
    @ObservedObject var service: NotchService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 0.984, green: 0.573, blue: 0.235))
                    .frame(width: 7, height: 7)
                Text(approval.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(approval.risk.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color(red: 0.984, green: 0.573, blue: 0.235))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.984, green: 0.573, blue: 0.235).opacity(0.16), in: Capsule())
            }

            let summary = approval.command.isEmpty ? approval.detail : approval.command
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    BaryonBridgeService.shared.sendApprovalDecision(id: approval.id, decision: "allow")
                } label: {
                    Text("Allow")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.243, green: 0.353, blue: 0.925), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    BaryonBridgeService.shared.sendApprovalDecision(id: approval.id, decision: "deny")
                } label: {
                    Text("Deny")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    BaryonBridgeService.shared.sendApprovalDecision(id: approval.id, decision: "inspect")
                } label: {
                    Text("Inspect")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, service.geometry.safeContentTop + 4)
        .padding(.bottom, 12)
        .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .top)
    }
}

struct NotchFairyToastPill: View {
    let toast: BaryonToast
    @ObservedObject var service: NotchService

    private var accentColor: Color {
        switch toast.accent {
        case "amber": return Color(red: 0.984, green: 0.573, blue: 0.235)
        case "cyan": return Color(red: 0.220, green: 0.741, blue: 0.973)
        default: return Color(red: 0.243, green: 0.353, blue: 0.925)
        }
    }

    var body: some View {
        Button {
            BaryonBridgeService.shared.dismissToast()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(accentColor).frame(width: 6, height: 6)
                if !toast.title.isEmpty {
                    Text(toast.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if !toast.detail.isEmpty {
                    Text(toast.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, service.geometry.safeContentTop)
            .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .center)
        }
        .buttonStyle(.plain)
    }
}

struct NotchFairyDockTargetView: View {
    let proximity: Double
    @ObservedObject var service: NotchService

    private var ringScale: CGFloat { 0.86 + CGFloat(min(1, max(0, proximity))) * 0.24 }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(Color(red: 0.243, green: 0.353, blue: 0.925), lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .scaleEffect(ringScale)
                    .shadow(color: Color(red: 0.243, green: 0.353, blue: 0.925).opacity(0.8), radius: 8)
                Circle()
                    .fill(Color(red: 0.243, green: 0.353, blue: 0.925).opacity(0.28 + proximity * 0.45))
                    .frame(width: 12, height: 12)
            }
            Text("Drop to dock Fairy")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, service.geometry.safeContentTop)
        .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .center)
    }
}
