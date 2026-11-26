// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Darwin
import Foundation

extension Notification.Name {
    static let baryonFairyStateChanged = Notification.Name("BaryonFairyStateChanged")
    static let baryonUnifiedTrayChanged = Notification.Name("BaryonUnifiedTrayChanged")
}

struct BaryonApproval: Identifiable, Equatable {
    let id: String
    let chatId: String
    let title: String
    let detail: String
    let command: String
    let risk: String
}

struct BaryonToast: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let accent: String
}

struct BaryonOpsProgress: Equatable {
    let current: String
    let index: Int
    let total: Int
}

struct BaryonRelayState: Equatable {
    let installed: Bool
    let reachable: Bool
    let miniName: String
    let route: String
    let problem: String
    let miniFreeBytes: Double
    let scheduleTime: String
    let lastSyncAtMs: Double
    let lastStatus: String
    let enabledJobs: Int
    let totalJobs: Int
    let pendingFiles: Int?
    let pendingBytes: Double?
    let diffing: Bool
    let running: BaryonOpsProgress?
}

struct BaryonSweepState: Equatable {
    let installed: Bool
    let diskFreeBytes: Double
    let diskTotalBytes: Double
    let thresholdGB: Double
    let belowThreshold: Bool
    let lastSweepAtMs: Double
    let lastFreedBytes: Double
    let totalFreedBytes: Double
    let readyBytes: Double?
    let running: BaryonOpsProgress?
}

struct BaryonCalendarEvent: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let start: String
    let end: String
    let allDay: Bool
    let location: String
    let joinUrl: String
    let url: String?
    let calendarName: String
    let color: String
}

struct BaryonUsageProvider: Equatable, Identifiable {
    let id: String
    let name: String
    let percentUsed: Int
    let resetText: String
}

struct BaryonUsageSummary: Equatable {
    let updatedAtMs: Double
    let todayCostUsd: Double
    let todayTokens: Int
    let providers: [BaryonUsageProvider]
}

/// Bidirectional NDJSON Unix-domain socket client connecting Vorssaint to Baryon (`vorssaint.sock`).
final class BaryonBridgeService: ObservableObject {
    static let shared = BaryonBridgeService()

    @Published private(set) var connected = false
    @Published private(set) var fairyState = "idle"
    @Published private(set) var stateTitle = ""
    @Published private(set) var stateSubtitle = ""
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var pendingApproval: BaryonApproval?
    @Published private(set) var toast: BaryonToast?
    @Published var fairyUndocked = false
    @Published var dockHoverActive = false
    @Published var dockHoverProximity = 0.0
    @Published private(set) var relayState: BaryonRelayState?
    @Published private(set) var sweepState: BaryonSweepState?
    @Published private(set) var opsError: String?
    @Published private(set) var googleCalendarConnected = false
    @Published private(set) var googleCalendarEvents: [BaryonCalendarEvent] = []
    @Published private(set) var baryonUsage: BaryonUsageSummary?

    private struct AskCallbacks {
        let onText: (String) -> Void
        let onDone: (Result<String, Error>) -> Void
    }

    private let ioQueue = DispatchQueue(label: "com.vorssaint.utils.baryon-bridge", qos: .utility)
    private let stateLock = NSLock()
    private var shouldRun = false
    private var activeFD: Int32 = -1
    private var readBuffer = Data()
    private var toastDismissWorkItem: DispatchWorkItem?
    private var askCallbacks: [String: AskCallbacks] = [:]

    private init() {}

    func start() {
        stateLock.lock()
        guard !shouldRun else { stateLock.unlock(); return }
        shouldRun = true
        stateLock.unlock()

        ioQueue.async { [weak self] in
            self?.connectionLoop()
        }
        VorssaintAlertMonitor.shared.start()
    }

    func stop() {
        stateLock.lock()
        shouldRun = false
        let fd = activeFD
        activeFD = -1
        let pending = askCallbacks
        askCallbacks.removeAll()
        stateLock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        DispatchQueue.main.async { [weak self] in
            for cb in pending.values {
                cb.onDone(.failure(NSError(domain: "BaryonBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Disconnected from Baryon."])))
            }
            self?.connected = false
            self?.pendingApproval = nil
            self?.toast = nil
            self?.fairyUndocked = false
            self?.dockHoverActive = false
            self?.dockHoverProximity = 0.0
        }
    }

    @discardableResult
    func send(_ payload: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return false
        }
        data.append(0x0A)
        stateLock.lock()
        let fd = activeFD
        stateLock.unlock()
        guard fd >= 0 else { return false }
        return writeAll(data, to: fd)
    }

    func sendApprovalDecision(id: String, decision: String) {
        send([
            "type": "fairy.approvalDecision",
            "id": id,
            "decision": decision,
        ])
        if decision == "allow" || decision == "deny" {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingApproval?.id == id else { return }
                self.pendingApproval = nil
                Self.refreshNotchIfAvailable()
            }
        }
    }

    func sendAsk(id: String = UUID().uuidString, text: String, context: [String: Any] = [:]) {
        send([
            "type": "fairy.ask",
            "id": id,
            "text": text,
            "context": context,
        ])
    }

    @discardableResult
    func askFairy(text: String,
                  context: [String: Any] = [:],
                  onText: @escaping (String) -> Void = { _ in },
                  onDone: @escaping (Result<String, Error>) -> Void) -> String {
        let id = UUID().uuidString
        stateLock.lock()
        askCallbacks[id] = AskCallbacks(onText: onText, onDone: onDone)
        stateLock.unlock()

        let sent = send([
            "type": "fairy.ask",
            "id": id,
            "text": text,
            "context": context,
        ])
        if !sent {
            stateLock.lock()
            let callbacks = askCallbacks.removeValue(forKey: id)
            stateLock.unlock()
            DispatchQueue.main.async {
                callbacks?.onDone(.failure(NSError(
                    domain: "BaryonBridge",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Baryon is not connected."]
                )))
            }
        }
        return id
    }

    func stopAsk(id: String? = nil) {
        stateLock.lock()
        if let id {
            askCallbacks.removeValue(forKey: id)
        } else {
            askCallbacks.removeAll()
        }
        stateLock.unlock()
        send(["type": "fairy.stop"])
    }

    @discardableResult
    func sendContextAction(action: String,
                           text: String = "",
                           files: [String] = [],
                           imagePath: String? = nil,
                           source: String = "") -> Bool {
        var payload: [String: Any] = [
            "type": "fairy.contextAction",
            "action": action,
            "text": text,
            "files": files,
            "source": source,
        ]
        if let imagePath, !imagePath.isEmpty {
            payload["imagePath"] = imagePath
        }
        return send(payload)
    }

    @discardableResult
    func sendOpsCommand(target: String, action: String, tier: String? = nil) -> Bool {
        var payload: [String: Any] = [
            "type": "vorssaint.ops",
            "target": target,
            "action": action,
        ]
        if let tier, !tier.isEmpty {
            payload["tier"] = tier
        }
        return send(payload)
    }

    @discardableResult
    func requestCalendarEvents() -> Bool {
        send(["type": "vorssaint.calendarRequest"])
    }

    @discardableResult
    func sendToolResult(id: String, ok: Bool, result: Any?, error: String?) -> Bool {
        var payload: [String: Any] = [
            "type": "vorssaint.toolResult",
            "id": id,
            "ok": ok,
        ]
        if let result {
            payload["result"] = result
        }
        if let error, !error.isEmpty {
            payload["error"] = error
        }
        return send(payload)
    }

    @discardableResult
    func sendSystemAlert(kind: String, title: String, detail: String, metrics: [String: Any] = [:]) -> Bool {
        send([
            "type": "vorssaint.alert",
            "kind": kind,
            "title": title,
            "detail": detail,
            "metrics": metrics,
        ])
    }

    @discardableResult
    func pushFeaturesState() -> Bool {
        let calStatus: String = switch Permissions.shared.calendarAccess {
        case .fullAccess: "full"
        case .denied, .restricted: "denied"
        default: "notDetermined"
        }
        return send([
            "type": "vorssaint.featuresState",
            "keptFeatures": BaryonHelperMode.keptFeatures.map(\.rawValue),
            "unifiedTray": UserDefaults.standard.bool(forKey: DefaultsKey.baryonUnifiedTray),
            "iCloudNotesSync": NotesSyncService.shared.iCloudSyncEnabled,
            "aiLauncherFolder": AILauncherService.shared.cliFolder.path,
            "hadronTodosPath": HadronTodoSyncService.todosFileURL.path,
            "hadronNotesPath": NotesSyncService.hadronNotesURL.path,
            "permissions": [
                "accessibility": Permissions.shared.accessibility,
                "screenRecording": Permissions.shared.screenRecording,
                "calendar": calStatus,
            ],
        ])
    }

    func sendUndock(x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, displayId: UInt32) {
        send([
            "type": "fairy.undock",
            "x": Double(x),
            "y": Double(y),
            "vx": Double(vx),
            "vy": Double(vy),
            "displayId": Int(displayId),
        ])
    }

    func sendQuickAction(_ action: String) {
        send([
            "type": "fairy.quickAction",
            "action": action,
        ])
    }

    func dismissToast() {
        DispatchQueue.main.async { [weak self] in
            self?.toastDismissWorkItem?.cancel()
            self?.toastDismissWorkItem = nil
            self?.toast = nil
            Self.refreshNotchIfAvailable()
        }
    }

    private static func refreshNotchIfAvailable() {
        guard AppFeature.notch.isAvailable else { return }
        NotchService.shared.refreshPresentation(animated: true)
    }

    private func connectionLoop() {
        var backoff: TimeInterval = 0.5
        while isRunning {
            let path = BaryonHelperMode.socketPath
            if let fd = connectUnixSocket(path: path) {
                backoff = 0.5
                stateLock.lock()
                activeFD = fd
                readBuffer.removeAll(keepingCapacity: false)
                stateLock.unlock()

                sendHello(on: fd)
                readLoop(on: fd)

                stateLock.lock()
                if activeFD == fd { activeFD = -1 }
                let pending = askCallbacks
                askCallbacks.removeAll()
                stateLock.unlock()
                Darwin.close(fd)
                DispatchQueue.main.async { [weak self] in
                    for cb in pending.values {
                        cb.onDone(.failure(NSError(domain: "BaryonBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Lost connection to Baryon."])))
                    }
                    self?.connected = false
                    self?.fairyUndocked = false
                    self?.dockHoverActive = false
                    self?.dockHoverProximity = 0.0
                }
            }
            guard isRunning else { break }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 5.0)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun
    }

    private func connectUnixSocket(path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count <= maxLen else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: utf8.count) { dst in
                utf8.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, utf8.count)
                }
            }
        }

        let len = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func sendHello(on fd: Int32) {
        let payload: [String: Any] = [
            "type": "hello",
            "app": "vorssaint",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "protocol": 1,
            "keptFeatures": BaryonHelperMode.keptFeatures.map(\.rawValue),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        data.append(0x0A)
        _ = writeAll(data, to: fd)
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    private func readLoop(on fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while isRunning {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, 250)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 { continue }
            if (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 && (pfd.revents & Int16(POLLIN)) == 0 {
                break
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            readBuffer.append(chunk, count: n)
            if readBuffer.count > (1 << 20) {
                break
            }
            drainLines()
        }
    }

    private func drainLines() {
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: 0..<newline)
            readBuffer.removeSubrange(0...newline)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else {
                continue
            }
            handleMessage(type: type, payload: obj)
        }
    }

    private func handleMessage(type: String, payload: [String: Any]) {
        switch type {
        case "hello.ack":
            DispatchQueue.main.async { [weak self] in
                self?.connected = true
                self?.pushFeaturesState()
            }
            _ = requestCalendarEvents()
        case "ping":
            send(["type": "pong", "ts": Date().timeIntervalSince1970])
        case "fairy.state":
            let nextState = (payload["state"] as? String) ?? "idle"
            let nextTitle = (payload["title"] as? String) ?? ""
            let nextSubtitle = (payload["subtitle"] as? String) ?? ""
            let nextAudio = (payload["audioLevel"] as? Double) ?? 0.0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fairyState = nextState
                self.stateTitle = nextTitle
                self.stateSubtitle = nextSubtitle
                self.audioLevel = nextAudio
                NotificationCenter.default.post(name: .baryonFairyStateChanged, object: nil)
            }
        case "fairy.approval":
            let clear = (payload["clear"] as? Bool) == true
            let approval: BaryonApproval?
            if clear {
                approval = nil
            } else if let id = payload["id"] as? String, !id.isEmpty {
                approval = BaryonApproval(
                    id: id,
                    chatId: (payload["chatId"] as? String) ?? "",
                    title: (payload["title"] as? String) ?? "Approval required",
                    detail: (payload["detail"] as? String) ?? "",
                    command: (payload["command"] as? String) ?? "",
                    risk: (payload["risk"] as? String) ?? "write"
                )
            } else {
                approval = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.pendingApproval = approval
                Self.refreshNotchIfAvailable()
            }
        case "fairy.toast":
            let clear = (payload["clear"] as? Bool) == true
            let nextToast: BaryonToast? = clear ? nil : BaryonToast(
                id: (payload["id"] as? String) ?? UUID().uuidString,
                title: (payload["title"] as? String) ?? "",
                detail: (payload["detail"] as? String) ?? "",
                accent: (payload["accent"] as? String) ?? "blue"
            )
            let durationMs = (payload["durationMs"] as? Double) ?? 4500.0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toastDismissWorkItem?.cancel()
                self.toastDismissWorkItem = nil
                self.toast = nextToast
                Self.refreshNotchIfAvailable()
                if let nextToast, durationMs > 0 {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.toast?.id == nextToast.id else { return }
                        self.toast = nil
                        Self.refreshNotchIfAvailable()
                    }
                    self.toastDismissWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + durationMs / 1000.0, execute: work)
                }
            }
        case "vorssaint.teleprompter":
            let action = (payload["action"] as? String) ?? "toggle"
            let text = payload["text"] as? String
            let title = payload["title"] as? String
            let wpm = payload["wpm"] as? Double
            let progress = payload["progress"] as? Double
            let autoPlay = (payload["autoPlay"] as? Bool) ?? false
            DispatchQueue.main.async {
                NotchTeleprompterService.shared.handleRemoteCommand(
                    action: action,
                    text: text,
                    title: title,
                    wpm: wpm,
                    progress: progress,
                    autoPlay: autoPlay
                )
            }
        case "fairy.undockAck":
            DispatchQueue.main.async {
                NotchFairyDragController.shared.handleUndockAck()
            }
        case "fairy.dockHover":
            let active = (payload["active"] as? Bool) ?? false
            let proximity = (payload["proximity"] as? Double) ?? 0.0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dockHoverActive = active
                self.dockHoverProximity = active ? proximity : 0.0
                Self.refreshNotchIfAvailable()
            }
        case "fairy.dock":
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dockHoverActive = false
                self.dockHoverProximity = 0.0
                self.fairyUndocked = false
                if NotchSupport.usesHapticFeedback() {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
                NotchService.shared.playFairyDockSettle()
            }
        case "fairy.text":
            guard let id = payload["id"] as? String else { return }
            let delta = (payload["text"] as? String) ?? ""
            stateLock.lock()
            let cb = askCallbacks[id]
            stateLock.unlock()
            guard let cb else { return }
            DispatchQueue.main.async {
                cb.onText(delta)
            }
        case "fairy.done":
            guard let id = payload["id"] as? String else { return }
            let finalText = (payload["text"] as? String) ?? ""
            stateLock.lock()
            let cb = askCallbacks.removeValue(forKey: id)
            stateLock.unlock()
            guard let cb else { return }
            DispatchQueue.main.async {
                cb.onDone(.success(finalText))
            }
        case "fairy.error":
            guard let id = payload["id"] as? String else { return }
            let message = (payload["message"] as? String) ?? "Fairy couldn't answer."
            stateLock.lock()
            let cb = askCallbacks.removeValue(forKey: id)
            stateLock.unlock()
            guard let cb else { return }
            DispatchQueue.main.async {
                cb.onDone(.failure(NSError(domain: "BaryonBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        case "vorssaint.opsState":
            let parsedRelay = (payload["relay"] as? [String: Any]).map(Self.parseRelayState)
            let parsedSweep = (payload["sweep"] as? [String: Any]).map(Self.parseSweepState)
            let nextError = (payload["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let parsedRelay { self.relayState = parsedRelay }
                if let parsedSweep { self.sweepState = parsedSweep }
                self.opsError = nextError
            }
        case "vorssaint.calendarEvents":
            let calConnected = (payload["connected"] as? Bool) ?? false
            let rawEvents = (payload["events"] as? [[String: Any]]) ?? []
            let parsedEvents: [BaryonCalendarEvent] = rawEvents.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(BaryonCalendarEvent.self, from: data)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.googleCalendarConnected = calConnected
                self.googleCalendarEvents = parsedEvents
                NotchCalendarService.shared.applyGoogleCalendarEvents(parsedEvents, connected: calConnected)
            }
        case "vorssaint.tool":
            let id = (payload["id"] as? String) ?? ""
            let tool = (payload["tool"] as? String) ?? ""
            let args = (payload["args"] as? [String: Any]) ?? [:]
            if !id.isEmpty, !tool.isEmpty {
                VorssaintToolExecutor.shared.execute(id: id, tool: tool, args: args)
            }
        case "vorssaint.preset":
            let preset = (payload["preset"] as? String) ?? ""
            VorssaintToolExecutor.shared.applyPreset(preset, params: payload)
        case "vorssaint.usage":
            let updatedAtMs = Self.num(payload["updatedAt"])
            let todayCostUsd = Self.num(payload["todayCostUsd"])
            let todayTokens = Int(Self.num(payload["todayTokens"]))
            let rawProviders = (payload["providers"] as? [[String: Any]]) ?? []
            let providers: [BaryonUsageProvider] = rawProviders.compactMap { dict in
                guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                return BaryonUsageProvider(
                    id: id,
                    name: (dict["name"] as? String) ?? id,
                    percentUsed: Int(Self.num(dict["percentUsed"])),
                    resetText: (dict["resetText"] as? String) ?? ""
                )
            }
            let summary = BaryonUsageSummary(
                updatedAtMs: updatedAtMs,
                todayCostUsd: todayCostUsd,
                todayTokens: todayTokens,
                providers: providers
            )
            DispatchQueue.main.async { [weak self] in
                self?.baryonUsage = summary
            }
        case "vorssaint.features":
            let action = (payload["action"] as? String) ?? "status"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch action {
                case "setUnifiedTray":
                    let enabled = (payload["enabled"] as? Bool) ?? false
                    UserDefaults.standard.set(enabled, forKey: DefaultsKey.baryonUnifiedTray)
                    NotificationCenter.default.post(name: .baryonUnifiedTrayChanged, object: nil)
                case "setICloudNotes":
                    let enabled = (payload["enabled"] as? Bool) ?? false
                    NotesSyncService.shared.iCloudSyncEnabled = enabled
                case "openSettings":
                    NotchService.shared.openSettings()
                case "openModule":
                    if let raw = payload["module"] as? String, let mod = NotchModule(rawValue: raw) {
                        NotchService.shared.open(mod, pinned: true, takeFocus: true)
                    }
                case "applyPreset":
                    if let preset = payload["preset"] as? String {
                        VorssaintToolExecutor.shared.applyPreset(preset, params: payload)
                    }
                default:
                    break
                }
                self.pushFeaturesState()
            }
        case "shutdown":
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        default:
            break
        }
    }

    private static func num(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func optNum(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func parseProgress(_ dict: [String: Any]?) -> BaryonOpsProgress? {
        guard let dict else { return nil }
        return BaryonOpsProgress(
            current: (dict["current"] as? String) ?? "",
            index: Int(num(dict["index"])),
            total: Int(num(dict["total"]))
        )
    }

    private static func parseRelayState(_ dict: [String: Any]) -> BaryonRelayState {
        BaryonRelayState(
            installed: (dict["installed"] as? Bool) ?? false,
            reachable: (dict["reachable"] as? Bool) ?? false,
            miniName: (dict["miniName"] as? String) ?? "Mac mini",
            route: (dict["route"] as? String) ?? "",
            problem: (dict["problem"] as? String) ?? "",
            miniFreeBytes: num(dict["miniFreeBytes"]),
            scheduleTime: (dict["scheduleTime"] as? String) ?? "",
            lastSyncAtMs: num(dict["lastSyncAt"]),
            lastStatus: (dict["lastStatus"] as? String) ?? "",
            enabledJobs: Int(num(dict["enabledJobs"])),
            totalJobs: Int(num(dict["totalJobs"])),
            pendingFiles: optNum(dict["pendingFiles"]).map { Int($0) },
            pendingBytes: optNum(dict["pendingBytes"]),
            diffing: (dict["diffing"] as? Bool) ?? false,
            running: parseProgress(dict["running"] as? [String: Any])
        )
    }

    private static func parseSweepState(_ dict: [String: Any]) -> BaryonSweepState {
        BaryonSweepState(
            installed: (dict["installed"] as? Bool) ?? false,
            diskFreeBytes: num(dict["diskFreeBytes"]),
            diskTotalBytes: num(dict["diskTotalBytes"]),
            thresholdGB: num(dict["thresholdGB"]),
            belowThreshold: (dict["belowThreshold"] as? Bool) ?? false,
            lastSweepAtMs: num(dict["lastSweepAt"]),
            lastFreedBytes: num(dict["lastFreedBytes"]),
            totalFreedBytes: num(dict["totalFreedBytes"]),
            readyBytes: optNum(dict["readyBytes"]),
            running: parseProgress(dict["running"] as? [String: Any])
        )
    }
}
