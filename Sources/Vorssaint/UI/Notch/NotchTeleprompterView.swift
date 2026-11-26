// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NotchTeleprompterView: View {
    @ObservedObject var service: NotchTeleprompterService
    let size: CGSize
    var interactive = true

    @State private var lastTick: Date?
    @State private var dragStartOffset: CGFloat?

    var body: some View {
        VStack(spacing: 8) {
            if interactive && service.isEditingScript {
                scriptEditor
            } else {
                prompterStage
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .notchBand(leading: {
            if interactive { leadingControls }
        }, trailing: {
            if interactive { trailingControls }
        })
        .onAppear {
            if interactive { service.onNotchModeAppear() }
        }
        .onDisappear {
            lastTick = nil
            if interactive { service.onNotchModeDisappear() }
        }
    }

    @ViewBuilder
    private var leadingControls: some View {
        NotchIconButton(
            symbol: service.isPlaying ? "pause.fill" : "play.fill",
            title: service.isPlaying ? "Pause" : "Play",
            selected: service.isPlaying
        ) {
            service.togglePlay()
        }
        NotchIconButton(symbol: "arrow.counterclockwise", title: "Reset to top") {
            service.reset()
        }
        NotchIconButton(symbol: "doc.on.clipboard", title: "Paste script from clipboard") {
            service.loadFromClipboard()
        }
        NotchIconButton(
            symbol: service.isEditingScript ? "checkmark" : "pencil",
            title: service.isEditingScript ? "Done editing" : "Edit script",
            selected: service.isEditingScript
        ) {
            service.toggleEditing()
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.243, green: 0.353, blue: 0.925))
                .help("Hidden from screen shares and recordings")
            Text("\(Int(service.wpm)) WPM")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 6)

        NotchIconButton(symbol: "minus", title: "Slower (-15 WPM)") {
            service.adjustWPM(by: -15)
        }
        NotchIconButton(symbol: "plus", title: "Faster (+15 WPM)") {
            service.adjustWPM(by: 15)
        }
        NotchIconButton(
            symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            title: "Mirror horizontally",
            selected: service.mirrorHorizontal
        ) {
            service.mirrorHorizontal.toggle()
        }
    }

    private var scriptEditor: some View {
        VStack(spacing: 8) {
            TextEditor(text: $service.script)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                Text("Tip: Space toggles Play · ↑/↓ adjusts WPM · Hidden in screen shares")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer()
                NotchPillButton(title: "Done", prominent: true) {
                    service.isEditingScript = false
                }
            }
        }
    }

    private var prompterStage: some View {
        ZStack(alignment: .topLeading) {
            // Subtle camera eye-line guide right below the camera cutout.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.243, green: 0.353, blue: 0.925).opacity(0.12))
                .frame(height: service.fontSize * 1.55)
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .allowsHitTesting(false)

            if interactive {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !service.isPlaying)) { context in
                    Color.clear
                        .frame(height: 0)
                        .onChange(of: context.date) { _, now in
                            advanceScroll(now: now)
                        }
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                Text(service.script)
                    .font(.system(size: interactive ? service.fontSize : 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, max(80, size.height * 0.6))
                    .scaleEffect(x: service.mirrorHorizontal ? -1 : 1, y: 1)
                    .offset(y: -service.scrollOffset)
            }
            .allowsHitTesting(false)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(NotchControlSurface(cornerRadius: 14, interactive: false))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard interactive else { return }
                    if dragStartOffset == nil { dragStartOffset = service.scrollOffset }
                    service.scrollOffset = max(0, (dragStartOffset ?? 0) - value.translation.height)
                }
                .onEnded { _ in
                    dragStartOffset = nil
                }
        )
    }

    private func advanceScroll(now: Date) {
        guard service.isPlaying else {
            lastTick = now
            return
        }
        defer { lastTick = now }
        guard let prev = lastTick else { return }
        let dt = min(0.1, max(0, now.timeIntervalSince(prev)))
        let pxPerSec = CGFloat(service.wpm / 60.0) * (service.fontSize * 0.72)
        service.scrollOffset += pxPerSec * CGFloat(dt)
    }
}
