// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NotchSystemView: View {
    let size: CGSize
    let select: (MetricDetailKind) -> Void
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.networkSpeedUnit) private var networkSpeedUnit = NetworkSpeedUnit.bytes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Card: Identifiable {
        let kind: MetricDetailKind
        let title: String
        let symbol: String
        let value: String?
        var detail: String? = nil
        var level: Double? = nil
        var history: [Double] = []
        var maxHistoryValue: Double? = nil
        var tint: Color = StratusTheme.cyan
        /// Set when the reading itself is the news, so the meter says so
        /// without the person having to read the number.
        var wantsAttention = false
        var id: String { kind.rawValue }
    }

    private var cards: [Card] {
        let snapshot = monitor.snapshot
        var cards: [Card] = []
        if AppFeature.monitorCPU.isAvailable {
            let tempText = snapshot.cpuTemperature.map { String(format: "%.0f°", $0) }
            cards.append(Card(kind: .cpu, title: l10n.s.cpuLabel, symbol: "cpu",
                              value: percent(snapshot.cpuUsage),
                              detail: tempText,
                              level: snapshot.cpuUsage,
                              history: snapshot.cpuHistory,
                              maxHistoryValue: 1.0,
                              tint: StratusTheme.orange,
                              wantsAttention: isBusy(snapshot.cpuUsage)))
        }
        if AppFeature.monitorGPU.isAvailable {
            let gpuTemp = snapshot.gpuTemperature.map { String(format: "%.0f°", $0) }
            cards.append(Card(kind: .gpu, title: l10n.s.gpuLabel, symbol: "rectangle.connected.to.line.below",
                              value: percent(snapshot.gpuUsage),
                              detail: gpuTemp,
                              level: snapshot.gpuUsage,
                              history: snapshot.gpuHistory,
                              maxHistoryValue: 1.0,
                              tint: StratusTheme.cyan,
                              wantsAttention: isBusy(snapshot.gpuUsage)))
        }
        if AppFeature.monitorMemory.isAvailable {
            let ratio = snapshot.memoryUsed.flatMap { used in
                snapshot.memoryTotal.flatMap { total in total > 0 ? Double(used) / Double(total) : nil }
            }
            cards.append(Card(kind: .memory, title: l10n.s.memorySection, symbol: "memorychip",
                              value: percent(ratio),
                              level: ratio,
                              history: snapshot.memoryHistory,
                              maxHistoryValue: 1.0,
                              tint: StratusTheme.purple,
                              wantsAttention: isBusy(ratio) || snapshot.memoryPressure == .critical))
        }
        if AppFeature.monitorPower.isAvailable, let power = snapshot.power, power.hasBattery {
            cards.append(Card(kind: .battery, title: l10n.s.batteryLabel,
                              symbol: power.externalConnected ? "battery.100percent.bolt" : "battery.100percent",
                              value: power.chargePercent.map { "\($0)%" },
                              level: power.chargePercent.map { Double($0) / 100 },
                              history: snapshot.batteryHistory,
                              maxHistoryValue: 1.0,
                              tint: StratusTheme.purple,
                              wantsAttention: !power.externalConnected && (power.chargePercent ?? 100) <= 20))
        }
        if AppFeature.monitorNetwork.isAvailable {
            let inBits = networkSpeedUnit == .bits
            cards.append(Card(kind: .network, title: l10n.s.networkSection, symbol: "network",
                              value: snapshot.netDownBytesPerSec.map { "↓ " + MetricFormat.networkRate($0, inBits: inBits) },
                              detail: snapshot.netUpBytesPerSec.map { "↑ " + MetricFormat.networkRate($0, inBits: inBits) },
                              history: snapshot.netDownHistory,
                              tint: StratusTheme.cyan))
        }
        if AppFeature.monitorDisk.isAvailable {
            let disk = snapshot.disk?.devices.first(where: { $0.mountPath == "/" })
                ?? snapshot.disk?.devices.first(where: \.isInternal)
            cards.append(Card(kind: .disk, title: l10n.s.diskAvailable.localizedCapitalized, symbol: "internaldrive",
                              value: disk.map { MetricFormat.diskBytes($0.freeBytes) },
                              level: disk.map { 1 - $0.usedFraction },
                              history: snapshot.diskReadHistory,
                              tint: StratusTheme.cyan,
                              wantsAttention: disk.map { 1 - $0.usedFraction < 0.1 } ?? false))
        }
        if AppFeature.monitorPower.isAvailable {
            let power = snapshot.power
            cards.append(Card(kind: .power, title: l10n.s.powerSection, symbol: "powerplug.fill",
                              value: power?.systemWatts.map(MetricFormat.wattsCompact),
                              detail: power?.externalConnected == true ? power?.adapterWatts.map(MetricFormat.watts) : nil,
                              history: snapshot.systemPowerHistory,
                              tint: StratusTheme.orange))
        }
        if AppFeature.fanControl.isAvailable, !snapshot.fanSpeeds.isEmpty {
            let strings = FeatureStrings.fanControl(l10n.language)
            cards.append(Card(kind: .fan, title: strings.title, symbol: "fanblades",
                              value: snapshot.fanSpeeds.first.map { String(format: strings.rpmFormat, Int($0.rounded())) },
                              tint: StratusTheme.cyan))
        }
        if AppFeature.connectedDevices.isAvailable {
            let strings = FeatureStrings.connectedDevices(l10n.language)
            cards.append(Card(kind: .connectedDevices, title: strings.title, symbol: "cable.connector",
                              value: "\(snapshot.connectedDevices.count)",
                              tint: StratusTheme.purple))
        }
        return cards
    }

    private func isBusy(_ level: Double?) -> Bool {
        guard let level, level.isFinite else { return false }
        return level >= 0.85
    }

    var body: some View {
        let cards = cards
        if cards.isEmpty {
            NotchEmptyView(symbol: "gauge.with.dots.needle.50percent", message: l10n.s.monitorUnavailable)
        } else {
            let inset = NotchLayout.systemHoverInset(width: size.width)
            let rows = NotchLayout.systemRowRanges(count: cards.count, width: size.width - inset * 2)
            let height = NotchLayout.railHeight(rows: rows.count, rowHeight: NotchLayout.systemCardHeight,
                                               spacing: NotchLayout.rowSpacing) + inset * 2
            Group {
                if height > size.height {
                    ScrollView {
                        grid(cards: cards, rows: rows).padding(inset)
                            .contentShape(Rectangle())
                    }
                } else {
                    grid(cards: cards, rows: rows).padding(inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .notchBand(trailing: {
                NotchIconButton(symbol: "sparkles", title: "Ask Fairy to diagnose") {
                    diagnoseWithFairy()
                }
            })
        }
    }

    private func diagnoseWithFairy() {
        let s = monitor.snapshot
        let lines = [
            "Diagnose this Mac's current system telemetry:",
            "CPU: \(percent(s.cpuUsage) ?? "—") (\(s.cpuTemperature.map { String(format: "%.1f°C", $0) } ?? "—"))",
            "GPU: \(percent(s.gpuUsage) ?? "—") (\(s.gpuTemperature.map { String(format: "%.1f°C", $0) } ?? "—"))",
            "Memory pressure: \(s.memoryPressure)",
            "Power: \(s.power?.systemWatts.map(MetricFormat.wattsCompact) ?? "—")",
            "Fans: \(s.fanSpeeds.map { "\(Int($0.rounded())) RPM" }.joined(separator: ", "))",
        ]
        _ = BaryonBridgeService.shared.sendContextAction(
            action: "ask",
            text: lines.joined(separator: "\n"),
            source: "system-monitor"
        )
    }

    private func grid(cards: [Card], rows: [Range<Int>]) -> some View {
        VStack(spacing: NotchLayout.rowSpacing) {
            ForEach(rows, id: \.lowerBound) { row in
                HStack(spacing: NotchLayout.rowSpacing) {
                    ForEach(Array(cards[row])) { card in
                        cardButton(card)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func cardButton(_ card: Card) -> some View {
        let accent = card.wantsAttention ? StratusTheme.orange : card.tint
        return Button { select(card.kind) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: card.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(card.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StratusTheme.textSecondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(card.value ?? "…")
                        .font(.system(size: card.detail == nil ? 20 : 14.5, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(StratusTheme.textPrimary)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: card.value)
                    if let detail = card.detail {
                        Text(detail)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(accent.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                if card.history.count >= 2 {
                    Sparkline(values: card.history, color: accent, maxValue: card.maxHistoryValue, fillOpacity: 0.22, lineWidth: 1.5)
                        .frame(height: 15)
                } else if let level = card.level {
                    NotchMeter(value: level, tint: accent)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: NotchLayout.systemCardHeight)
            .modifier(StratusCardSurface(cornerRadius: 16))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(card.kind) }
        .accessibilityLabel(card.title)
        .accessibilityValue([card.value, card.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private func percent(_ value: Double?) -> String? {
        value.flatMap { $0.isFinite ? "\(Int((min(1, max(0, $0)) * 100).rounded()))%" : nil }
    }
}
