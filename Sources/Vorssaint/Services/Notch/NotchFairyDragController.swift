// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore

private final class FairyDragOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FairyDragCanvasView: NSView {
    let tetherLayer = CAShapeLayer()
    let tetherGlowLayer = CAShapeLayer()
    let orbBackdropLayer = CAShapeLayer()
    let orbRingLayer = CAShapeLayer()
    let orbHaloLayer = CALayer()
    let mascotHost = NotchMascotHostView(frame: CGRect(x: 0, y: 0, width: 84, height: 84))

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        tetherGlowLayer.fillColor = nil
        tetherGlowLayer.strokeColor = NSColor(red: 0.243, green: 0.353, blue: 0.925, alpha: 0.55).cgColor
        tetherGlowLayer.lineWidth = 2.0
        tetherGlowLayer.lineCap = .round

        tetherLayer.fillColor = NSColor(red: 0.020, green: 0.020, blue: 0.028, alpha: 0.96).cgColor
        tetherLayer.strokeColor = NSColor(red: 0.243, green: 0.353, blue: 0.925, alpha: 0.42).cgColor
        tetherLayer.lineWidth = 1.0

        orbHaloLayer.backgroundColor = NSColor(red: 0.243, green: 0.353, blue: 0.925, alpha: 0.24).cgColor
        orbHaloLayer.shadowColor = NSColor(red: 0.243, green: 0.353, blue: 0.925, alpha: 1.0).cgColor
        orbHaloLayer.shadowRadius = 18
        orbHaloLayer.shadowOpacity = 0.85
        orbHaloLayer.shadowOffset = .zero

        orbBackdropLayer.fillColor = NSColor(red: 0.020, green: 0.020, blue: 0.028, alpha: 0.94).cgColor
        orbRingLayer.fillColor = nil
        orbRingLayer.strokeColor = NSColor(red: 0.35, green: 0.48, blue: 0.98, alpha: 0.65).cgColor
        orbRingLayer.lineWidth = 1.4

        layer?.addSublayer(tetherGlowLayer)
        layer?.addSublayer(tetherLayer)
        layer?.addSublayer(orbHaloLayer)
        layer?.addSublayer(orbBackdropLayer)
        layer?.addSublayer(orbRingLayer)

        mascotHost.configure(look: NotchMascotLook(style: .fairy, shape: .ball, palette: .pearl),
                             size: 54, mood: .determined, idles: false,
                             reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                             animated: false)
        addSubview(mascotHost)
    }

    required init?(coder: NSCoder) { nil }

    func renderTether(anchor: CGPoint, center: CGPoint, radius: CGFloat, detached: Bool,
                      vx: CGFloat, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if detached || reduceMotion {
            tetherLayer.path = nil
            tetherGlowLayer.path = nil
        } else {
            let pull = hypot(center.x - anchor.x, center.y - anchor.y)
            let stretchRatio = min(1.0, max(0.0, pull / 70.0))
            let baseHalfWidth = max(7.0, 26.0 * (1.0 - stretchRatio * 0.62))
            let neckHalfWidth = max(4.0, 12.0 * (1.0 - stretchRatio * 0.55))

            let leftTop = CGPoint(x: anchor.x - baseHalfWidth, y: anchor.y)
            let rightTop = CGPoint(x: anchor.x + baseHalfWidth, y: anchor.y)
            let leftOrb = CGPoint(x: center.x - radius * 0.82, y: center.y - radius * 0.25)
            let rightOrb = CGPoint(x: center.x + radius * 0.82, y: center.y - radius * 0.25)
            let midY = (anchor.y + center.y) * 0.52

            let neck = CGMutablePath()
            neck.move(to: leftTop)
            neck.addCurve(to: leftOrb,
                          control1: CGPoint(x: anchor.x - neckHalfWidth, y: midY),
                          control2: CGPoint(x: center.x - radius * 0.65, y: center.y - radius * 0.72))
            neck.addLine(to: rightOrb)
            neck.addCurve(to: rightTop,
                          control1: CGPoint(x: center.x + radius * 0.65, y: center.y - radius * 0.72),
                          control2: CGPoint(x: anchor.x + neckHalfWidth, y: midY))
            neck.closeSubpath()

            tetherLayer.path = neck
            tetherGlowLayer.path = neck
        }

        let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let circlePath = CGPath(ellipseIn: circleRect, transform: nil)
        orbBackdropLayer.path = circlePath
        orbBackdropLayer.opacity = detached ? 0.22 : 1.0
        orbRingLayer.path = circlePath
        orbRingLayer.opacity = detached ? 0.55 : 0.85

        let haloRadius = radius * 1.18
        orbHaloLayer.bounds = CGRect(x: 0, y: 0, width: haloRadius * 2, height: haloRadius * 2)
        orbHaloLayer.position = center
        orbHaloLayer.cornerRadius = haloRadius
        orbHaloLayer.opacity = detached ? 0.9 : 0.45

        let hostSide = max(54.0, radius * 2.15)
        mascotHost.frame = CGRect(x: center.x - hostSide / 2, y: center.y - hostSide / 2, width: hostSide, height: hostSide)
        mascotHost.configure(look: NotchMascotLook(style: .fairy, shape: .ball, palette: .pearl),
                             size: radius * 1.9,
                             mood: detached ? .happy : .determined,
                             idles: false,
                             reduceMotion: reduceMotion,
                             animated: false)
        let tilt = reduceMotion ? 0 : min(0.21, max(-0.21, -vx / 1400.0))
        mascotHost.layer?.setAffineTransform(CGAffineTransform(rotationAngle: tilt))

        CATransaction.commit()
    }
}

/// Phase 2 controller for the 120Hz elastic notch tether & free-drag orb
/// that hands Fairy off to Electron's pre-warmed `companionWindow`.
@MainActor
final class NotchFairyDragController {
    static let shared = NotchFairyDragController()

    static let detachThreshold: CGFloat = 70
    static let startThreshold: CGFloat = 10

    private var overlayPanel: FairyDragOverlayPanel?
    private var canvasView: FairyDragCanvasView?
    private var fadeOutWork: DispatchWorkItem?
    private var activeTracking = false

    private init() {}

    func canStartDrag() -> Bool {
        !NotchService.shared.expanded
            && BaryonBridgeService.shared.connected
            && !BaryonBridgeService.shared.fairyUndocked
            && !activeTracking
    }

    func trackDrag(from initialEvent: NSEvent, in notchWindow: NSWindow, onPlainClick: @escaping () -> Void) {
        activeTracking = true
        defer { activeTracking = false }

        let anchorScreen = CGPoint(x: notchWindow.frame.midX, y: notchWindow.frame.minY + 14)
        let startPoint = NSEvent.mouseLocation
        var lastPoint = startPoint
        var lastTime = initialEvent.timestamp
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var startedTether = false
        var detached = false
        var cancelled = false

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        notchWindow.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
            timeout: 60.0,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }

            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape cancels cleanly
                    cancelled = true
                    stop.pointee = true
                }
                return
            }

            let pt = NSEvent.mouseLocation
            let dt = max(0.004, CGFloat(event.timestamp - lastTime))
            let instVx = (pt.x - lastPoint.x) / dt
            let instVy = (pt.y - lastPoint.y) / dt
            vx = vx * 0.65 + instVx * 0.35
            vy = vy * 0.65 + instVy * 0.35
            lastPoint = pt
            lastTime = event.timestamp

            let dragDown = max(0, startPoint.y - pt.y)
            let pullDown = max(0, anchorScreen.y - pt.y)

            if event.type == .leftMouseDragged {
                if !startedTether && dragDown >= Self.startThreshold {
                    startedTether = true
                    self.showOverlay(anchorScreen: anchorScreen, pointerScreen: pt, pullDown: pullDown,
                                     detached: false, vx: vx, reduceMotion: reduceMotion)
                }

                if startedTether {
                    if !detached && pullDown >= Self.detachThreshold {
                        detached = true
                        if NotchSupport.usesHapticFeedback() {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        BaryonBridgeService.shared.fairyUndocked = true
                        NotchService.shared.refreshPresentation(animated: true)
                    }
                    self.updateOverlay(anchorScreen: anchorScreen, pointerScreen: pt, pullDown: pullDown,
                                       detached: detached, vx: vx, reduceMotion: reduceMotion)
                }
            } else if event.type == .leftMouseUp {
                stop.pointee = true
            }
        }

        if cancelled {
            cancelDrag(anchorScreen: anchorScreen, from: lastPoint, reduceMotion: reduceMotion)
            return
        }

        if !startedTether {
            closeOverlayImmediately()
            onPlainClick()
            return
        }

        if !detached {
            // Released inside tether threshold: snap cleanly back into notch.
            snapBackAndClose(anchorScreen: anchorScreen, from: lastPoint, reduceMotion: reduceMotion)
            return
        }

        // Detached drop: hand off to pre-warmed Electron companion window.
        let dropScreen = NSScreen.screens.first(where: { $0.frame.contains(lastPoint) }) ?? NSScreen.main
        let displayId = (dropScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        BaryonBridgeService.shared.sendUndock(x: lastPoint.x, y: lastPoint.y, vx: vx, vy: vy, displayId: displayId)

        let timeout = DispatchWorkItem { [weak self] in
            self?.fadeOutOverlay(duration: reduceMotion ? 0.12 : 0.14)
        }
        fadeOutWork?.cancel()
        fadeOutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: timeout)
    }

    func handleUndockAck() {
        fadeOutWork?.cancel()
        fadeOutWork = nil
        fadeOutOverlay(duration: 0.12)
    }

    private func desktopBounds() -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return union.isNull ? CGRect(x: 0, y: 0, width: 1512, height: 982) : union
    }

    private func showOverlay(anchorScreen: CGPoint, pointerScreen: CGPoint, pullDown: CGFloat,
                             detached: Bool, vx: CGFloat, reduceMotion: Bool) {
        fadeOutWork?.cancel()
        fadeOutWork = nil
        let frame = desktopBounds()
        let panel = overlayPanel ?? FairyDragOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setFrame(frame, display: false)
        panel.alphaValue = 1

        let canvas = canvasView ?? FairyDragCanvasView(frame: CGRect(origin: .zero, size: frame.size))
        canvas.frame = CGRect(origin: .zero, size: frame.size)
        if panel.contentView !== canvas {
            panel.contentView = canvas
        }
        overlayPanel = panel
        canvasView = canvas

        updateOverlay(anchorScreen: anchorScreen, pointerScreen: pointerScreen, pullDown: pullDown,
                      detached: detached, vx: vx, reduceMotion: reduceMotion)
        panel.orderFrontRegardless()
    }

    private func canvasPoint(fromScreen point: CGPoint, in panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: panelFrame.maxY - point.y)
    }

    private func updateOverlay(anchorScreen: CGPoint, pointerScreen: CGPoint, pullDown: CGFloat,
                               detached: Bool, vx: CGFloat, reduceMotion: Bool) {
        guard let panel = overlayPanel, let canvas = canvasView else { return }
        let anchor = canvasPoint(fromScreen: anchorScreen, in: panel.frame)
        let center = canvasPoint(fromScreen: pointerScreen, in: panel.frame)
        let ratio = min(1.0, max(0.0, pullDown / Self.detachThreshold))
        let radius: CGFloat = detached ? 40.0 : (18.0 + ratio * 18.0)
        canvas.renderTether(anchor: anchor, center: center, radius: radius,
                            detached: detached, vx: vx, reduceMotion: reduceMotion)
    }

    private func snapBackAndClose(anchorScreen: CGPoint, from lastPoint: CGPoint, reduceMotion: Bool) {
        guard let panel = overlayPanel else { return }
        let duration: TimeInterval = reduceMotion ? 0.12 : 0.20
        updateOverlay(anchorScreen: anchorScreen, pointerScreen: anchorScreen, pullDown: 0,
                      detached: false, vx: 0, reduceMotion: reduceMotion)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.closeOverlayImmediately()
            }
        })
    }

    private func cancelDrag(anchorScreen: CGPoint, from lastPoint: CGPoint, reduceMotion: Bool) {
        if BaryonBridgeService.shared.fairyUndocked {
            BaryonBridgeService.shared.fairyUndocked = false
            NotchService.shared.refreshPresentation(animated: true)
        }
        snapBackAndClose(anchorScreen: anchorScreen, from: lastPoint, reduceMotion: reduceMotion)
    }

    private func fadeOutOverlay(duration: TimeInterval) {
        guard let panel = overlayPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.closeOverlayImmediately()
            }
        })
    }

    private func closeOverlayImmediately() {
        overlayPanel?.orderOut(nil)
    }
}
