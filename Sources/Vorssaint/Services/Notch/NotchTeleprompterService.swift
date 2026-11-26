// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Native Notch-mode Teleprompter. Opens inside the Dynamic Island itself
/// (instead of a separate popup panel) and forces the island panel's
/// `sharingType` to `.none` while active so scripts never leak into screen shares.
@MainActor
final class NotchTeleprompterService: ObservableObject {
    static let shared = NotchTeleprompterService()

    @Published var isVisible = false
    @Published var isPlaying = false
    @Published var isEditingScript = false
    @Published var title = "Teleprompter"
    @Published var script = "Paste or edit a script below, or send one from Baryon, to start scrolling right beneath your camera."
    @Published var wpm: Double = 145
    @Published var fontSize: CGFloat = 19
    @Published var mirrorHorizontal = false
    @Published var scrollOffset: CGFloat = 0

    private var keyMonitor: Any?

    private init() {}

    func toggle() {
        let notch = NotchService.shared
        if notch.expanded && notch.selected == .teleprompter {
            hide()
        } else {
            show()
        }
    }

    func show() {
        isVisible = true
        NotchService.shared.open(.teleprompter, pinned: true, takeFocus: true)
        installKeyMonitor()
    }

    func hide() {
        isPlaying = false
        isEditingScript = false
        isVisible = false
        removeKeyMonitor()
        let notch = NotchService.shared
        if notch.expanded && notch.selected == .teleprompter {
            notch.pinned = false
            notch.collapse()
        }
    }

    func onNotchModeAppear() {
        isVisible = true
        installKeyMonitor()
    }

    func onNotchModeDisappear() {
        isPlaying = false
        isEditingScript = false
        isVisible = false
        removeKeyMonitor()
    }

    func play() {
        isEditingScript = false
        let notch = NotchService.shared
        if !(notch.expanded && notch.selected == .teleprompter) {
            show()
        }
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func toggleEditing() {
        if !isEditingScript { pause() }
        isEditingScript.toggle()
    }

    func reset() {
        scrollOffset = 0
    }

    func nudge(by delta: CGFloat) {
        scrollOffset = max(0, scrollOffset + delta)
    }

    func adjustWPM(by delta: Double) {
        wpm = min(260, max(80, wpm + delta))
    }

    func adjustFontSize(by delta: CGFloat) {
        fontSize = min(28, max(14, fontSize + delta))
    }

    func load(text: String, title: String? = nil, wpm: Double? = nil, autoPlay: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            script = trimmed
            scrollOffset = 0
        }
        if let title, !title.isEmpty {
            self.title = title
        }
        if let wpm {
            self.wpm = min(260, max(80, wpm))
        }
        isEditingScript = false
        show()
        if autoPlay { play() }
    }

    func loadFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        script = trimmed
        title = "Clipboard Script"
        scrollOffset = 0
        isEditingScript = false
    }

    func advanceToProgress(_ progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        let estimatedContentHeight = max(200, CGFloat(script.count) * fontSize * 0.042)
        scrollOffset = estimatedContentHeight * CGFloat(clamped)
    }

    func handleRemoteCommand(action: String, text: String?, title: String?, wpm: Double?, progress: Double?, autoPlay: Bool) {
        switch action {
        case "load":
            load(text: text ?? "", title: title, wpm: wpm, autoPlay: autoPlay)
        case "play":
            play()
        case "pause":
            pause()
        case "toggle":
            toggle()
        case "close", "hide":
            hide()
        case "reset":
            reset()
        case "advance":
            if let progress { advanceToProgress(progress) }
        default:
            toggle()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isEditingScript else { return event }
            let notch = NotchService.shared
            guard notch.expanded, notch.selected == .teleprompter,
                  notch.presentationWindow?.isKeyWindow == true else {
                return event
            }
            if let editor = notch.presentationWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }
            switch event.keyCode {
            case 49: // Space
                self.togglePlay()
                return nil
            case 126: // Up arrow
                self.adjustWPM(by: 10)
                return nil
            case 125: // Down arrow
                self.adjustWPM(by: -10)
                return nil
            case 15 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty: // R
                self.reset()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
