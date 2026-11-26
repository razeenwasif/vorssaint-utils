// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Dynamic Island controls & telemetry for Baryon's Relay (repo sync to Mac mini)
/// and Sweep (automated & on-demand disk cleaner).
struct NotchRelaySweepView: View {
    @ObservedObject private var bridge = BaryonBridgeService.shared
    let size: CGSize
    var interactive = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error = bridge.opsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }

                HStack(alignment: .top, spacing: 8) {
                    relayCard
                    sweepCard
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .frame(width: size.width, height: size.height, alignment: .top)
        .notchBand(leading: {
            HStack(spacing: 6) {
                Circle()
                    .fill(bridge.connected ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
                Text(bridge.connected ? "Baryon Ops" : "Offline")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 4)
        }, trailing: {
            if interactive {
                NotchIconButton(symbol: "arrow.clockwise", title: "Refresh Relay & Sweep") {
                    bridge.sendOpsCommand(target: "all", action: "state")
                }
            }
        })
        .onAppear {
            if interactive {
                bridge.sendOpsCommand(target: "all", action: "state")
            }
        }
    }

    private var relayCard: some View {
        let state = bridge.relayState
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                Text("Relay")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                relayBadge(state)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let state {
                    if !state.installed {
                        detailLine("relay binary not installed (~/.local/bin/relay)")
                    } else {
                        detailLine("\(state.enabledJobs)/\(state.totalJobs) repos · Daily \(state.scheduleTime.isEmpty ? "—" : state.scheduleTime)")
                        if state.miniFreeBytes > 0 {
                            detailLine("\(state.miniName): \(Self.formatBytes(state.miniFreeBytes)) free")
                        } else if !state.problem.isEmpty {
                            detailLine(state.problem)
                        }
                        if let files = state.pendingFiles {
                            detailLine("Pending: \(files) files (\(Self.formatBytes(state.pendingBytes ?? 0)))")
                        } else if state.lastSyncAtMs > 0 {
                            detailLine("Last sync \(Self.relativeTime(ms: state.lastSyncAtMs))")
                        }
                    }
                } else {
                    detailLine(bridge.connected ? "Loading Relay status…" : "Waiting for Baryon")
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if state?.running != nil {
                    actionPill("Stop", tint: .orange, interactive: interactive) {
                        bridge.sendOpsCommand(target: "relay", action: "stop")
                    }
                } else {
                    actionPill("Sync", tint: Color(red: 0.24, green: 0.47, blue: 0.96), interactive: interactive && (state?.installed ?? true)) {
                        bridge.sendOpsCommand(target: "relay", action: "sync")
                    }
                    actionPill(state?.diffing == true ? "Diff…" : "Diff", tint: .white.opacity(0.16), interactive: interactive && (state?.installed ?? true) && state?.diffing != true) {
                        bridge.sendOpsCommand(target: "relay", action: "diff")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .modifier(NotchControlSurface(cornerRadius: 14, interactive: false))
    }

    private var sweepCard: some View {
        let state = bridge.sweepState
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.square.filled.on.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.30, green: 0.80, blue: 0.92))
                Text("Sweep")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                sweepBadge(state)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let state {
                    if !state.installed {
                        detailLine("sweep binary not installed (~/.local/bin/sweep)")
                    } else {
                        detailLine("Free \(Self.formatBytes(state.diskFreeBytes)) · Line \(Int(state.thresholdGB)) GB")
                        if let ready = state.readyBytes {
                            detailLine("Reclaimable: \(Self.formatBytes(ready))")
                        } else if state.totalFreedBytes > 0 {
                            detailLine("Total freed: \(Self.formatBytes(state.totalFreedBytes))")
                        }
                        if state.lastSweepAtMs > 0 {
                            detailLine("Last clean \(Self.relativeTime(ms: state.lastSweepAtMs))")
                        }
                    }
                } else {
                    detailLine(bridge.connected ? "Loading Sweep status…" : "Waiting for Baryon")
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                if state?.running != nil {
                    actionPill("Stop", tint: .orange, interactive: interactive) {
                        bridge.sendOpsCommand(target: "sweep", action: "stop")
                    }
                } else {
                    actionPill("Scan", tint: .white.opacity(0.16), interactive: interactive && (state?.installed ?? true)) {
                        bridge.sendOpsCommand(target: "sweep", action: "scan")
                    }
                    actionPill("Safe", tint: Color(red: 0.14, green: 0.65, blue: 0.72), interactive: interactive && (state?.installed ?? true)) {
                        bridge.sendOpsCommand(target: "sweep", action: "clean", tier: "safe")
                    }
                    actionPill("Clean", tint: Color(red: 0.24, green: 0.47, blue: 0.96), interactive: interactive && (state?.installed ?? true)) {
                        bridge.sendOpsCommand(target: "sweep", action: "clean")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .modifier(NotchControlSurface(cornerRadius: 14, interactive: false))
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.60))
            .lineLimit(2)
    }

    @ViewBuilder
    private func relayBadge(_ state: BaryonRelayState?) -> some View {
        let label: String = {
            guard let state else { return "—" }
            if !state.installed { return "Missing" }
            if let r = state.running { return r.total > 0 ? "\(r.index)/\(r.total)" : "Syncing" }
            return state.reachable ? "Online" : "Offline"
        }()
        let color: Color = {
            guard let state else { return .secondary }
            if !state.installed { return .orange }
            if state.running != nil { return Color(red: 0.45, green: 0.72, blue: 1.0) }
            return state.reachable ? .green : .orange
        }()
        statusChip(label, color: color)
    }

    @ViewBuilder
    private func sweepBadge(_ state: BaryonSweepState?) -> some View {
        let label: String = {
            guard let state else { return "—" }
            if !state.installed { return "Missing" }
            if let r = state.running { return r.total > 0 ? "\(r.index)/\(r.total)" : "Running" }
            return state.belowThreshold ? "Low Disk" : "Healthy"
        }()
        let color: Color = {
            guard let state else { return .secondary }
            if !state.installed { return .orange }
            if state.running != nil { return Color(red: 0.30, green: 0.80, blue: 0.92) }
            return state.belowThreshold ? .orange : .green
        }()
        statusChip(label, color: color)
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }

    private func actionPill(_ title: String, tint: Color, interactive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard interactive else { return }
            action()
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
    }

    private static func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    private static func relativeTime(ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
