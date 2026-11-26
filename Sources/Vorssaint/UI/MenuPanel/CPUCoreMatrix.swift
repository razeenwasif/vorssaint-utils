// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// One bar per logical core, grouped by core class (Performance, Efficiency…)
/// and wrapped to the available width.
struct CPUCoreMatrix: View {
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var width: CGFloat = 280
    let usage: [Double?]

    var body: some View {
        let strings = FeatureStrings.cpuCores(l10n.language)
        let layout: [[CPUCoreSegment]] = CPUCoreLayout.rows(groups: CPUCoreTopology.groups(for: usage.count),
                                                            width: max(70, width - 16))
        let rowCount = CGFloat(layout.count)
        let height: CGFloat = rowCount * 88 + max(0, rowCount - 1) * 12 + 16
        GeometryReader { proxy in
            grid(layout, strings: strings)
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in width = value }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.title)
        .accessibilityHint(strings.hint)
    }

    private func grid(_ layout: [[CPUCoreSegment]], strings: CPUCoreFeatureStrings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(layout.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(layout[row].indices, id: \.self) { index in
                        coreGroup(layout[row][index], strings: strings)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StratusTheme.cardBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StratusTheme.hairline, lineWidth: 0.75))
    }

    private func coreGroup(_ segment: CPUCoreSegment, strings: CPUCoreFeatureStrings) -> some View {
        let lowerName = segment.group.name.lowercased()
        let name = switch lowerName {
        case "super": strings.superCores
        case "performance": strings.performanceCores
        case "efficiency": strings.efficiencyCores
        default: segment.group.name
        }
        let barColor: Color = switch lowerName {
        case "performance": StratusTheme.orange
        case "super": StratusTheme.purple
        default: StratusTheme.cyan
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(segment.group.indices, id: \.self) { index in
                    coreBar(index, width: segment.barWidth, color: barColor, strings: strings)
                }
            }
            Text("\(name) ×\(segment.group.indices.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: 22, alignment: .topLeading)
        }
        .frame(width: segment.width, alignment: .leading)
    }

    private func coreBar(_ index: Int, width: Double, color: Color, strings: CPUCoreFeatureStrings) -> some View {
        let value: Double? = usage[index]
        let increasedContrast = contrast == .increased
        return GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.04))
                if let value {
                    LinearGradient(
                        colors: [color, color.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: proxy.size.height * value)
                } else {
                    Text("–").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(increasedContrast ? 0.65 : 0.28),
                                  style: StrokeStyle(lineWidth: increasedContrast ? 1.5 : 0.75,
                                                     dash: value == nil ? [2, 2] : []))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
        }
        .frame(width: width, height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: strings.coreFormat, index + 1))
        .accessibilityValue(value.map(MetricFormat.percent) ?? "–")
    }
}
