// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// A small history graph: a filled area under a smooth polyline. Hand-drawn with
/// `Path` so the app needs no charting framework (and stays clear of the SwiftUI
/// macro plugins the Command Line Tools cannot load).
///
/// `maxValue` fixes the vertical scale (CPU/memory use 1.0 for an absolute 0–100%
/// reading); when nil the graph auto-scales to its own peak (network, power).
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double? = nil
    var fillOpacity: Double = 0.16
    var lineWidth: CGFloat = 1.5
    var showsZeroBaseline = false

    var body: some View {
        GeometryReader { geometry in
            let baselineY = max(0.5, geometry.size.height - 0.5)
            let points = points(in: geometry.size, baselineY: baselineY)
            if points.count >= 2 {
                ZStack {
                    splineFillPath(points: points, baselineY: baselineY)
                        .fill(
                            LinearGradient(colors: [color.opacity(fillOpacity), color.opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    if showsZeroBaseline {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: baselineY))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: baselineY))
                        }
                        .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    }
                    splineStrokePath(points: points)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .shadow(color: color.opacity(0.42), radius: 3.5, x: 0, y: 1)
                }
            }
        }
    }

    private func splineStrokePath(points: [CGPoint]) -> Path {
        Path { path in
            addSmoothCurve(through: points, to: &path)
        }
    }

    private func splineFillPath(points: [CGPoint], baselineY: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: points[0].x, y: baselineY))
            path.addLine(to: points[0])
            addSmoothCurve(through: points, to: &path, moveToFirst: false)
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: baselineY))
            path.closeSubpath()
        }
    }

    /// Smooth Catmull-Rom to cubic Bezier conversion clamped horizontally/vertically inside plot bounds.
    private func addSmoothCurve(through points: [CGPoint], to path: inout Path, moveToFirst: Bool = true) {
        guard points.count >= 2 else { return }
        if moveToFirst { path.move(to: points[0]) }
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }
        let minY: CGFloat = 0.5
        let maxY = points.map(\.y).max() ?? 0.5
        let clampY: (CGFloat) -> CGFloat = { min(max(minY, $0), maxY) }
        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = (i + 2) < points.count ? points[i + 2] : p2
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6.0,
                y: clampY(p1.y + (p2.y - p0.y) / 6.0)
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6.0,
                y: clampY(p2.y - (p3.y - p1.y) / 6.0)
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    private func points(in size: CGSize, baselineY: CGFloat) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let peak = max(maxValue ?? (values.max() ?? 1), 0.0001)
        let topY: CGFloat = 0.5
        let plotHeight = max(1, baselineY - topY)
        let lastIndex = values.count - 1
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(lastIndex)
            let normalized = min(1, max(0, value / peak))
            let y = baselineY - plotHeight * CGFloat(normalized)
            return CGPoint(x: x, y: y)
        }
    }
}

extension View {
    /// Marks the top of a graph with a dashed rule and names its value on that
    /// rule, so the number reads as the scale and not as a sample.
    func graphCeilingLabel(_ text: String) -> some View {
        modifier(GraphCeilingLabel(text: text))
    }
}

private struct GraphCeilingLabel: ViewModifier {
    @AppStorage(DefaultsKey.monitorGraphScale) private var visible = true
    let text: String

    func body(content: Content) -> some View {
        if visible {
            content
                .overlay {
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 0.5))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                        }
                        .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    .allowsHitTesting(false)
                }
                // Over the oldest samples, so the newest stay clear.
                .overlay(alignment: .topLeading) {
                    Text(text)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}
