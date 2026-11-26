// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Executes read-only and approval-gated OS tools requested by Baryon over `vorssaint.sock`.
final class VorssaintToolExecutor {
    static let shared = VorssaintToolExecutor()
    private init() {}

    func execute(id: String, tool: String, args: [String: Any]) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Self.runTool(tool: tool, args: args)
                BaryonBridgeService.shared.sendToolResult(id: id, ok: true, result: result, error: nil)
            } catch {
                BaryonBridgeService.shared.sendToolResult(id: id, ok: false, result: nil, error: error.localizedDescription)
            }
        }
    }

    func applyPreset(_ preset: String, params: [String: Any]) {
        DispatchQueue.main.async {
            let clean = preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch clean {
            case "meeting":
                if !KeepAwakeManager.shared.isActive {
                    KeepAwakeManager.shared.activate(minutes: 90, trigger: .manual)
                }
                QuickToolHUD.show(icon: "video.fill", message: "Meeting preset active")
            case "study", "notebook":
                if !KeepAwakeManager.shared.isActive {
                    KeepAwakeManager.shared.activate(minutes: 120, trigger: .manual)
                }
                QuickToolHUD.show(icon: "book.fill", message: "Study preset active")
            case "work", "analytics":
                if !KeepAwakeManager.shared.isActive {
                    KeepAwakeManager.shared.activate(minutes: 0, trigger: .manual)
                }
                QuickToolHUD.show(icon: "cpu", message: "Work preset active")
            case "off", "normal":
                if KeepAwakeManager.shared.isActive {
                    KeepAwakeManager.shared.toggle()
                }
                QuickToolHUD.show(icon: "moon.zzz", message: "Preset cleared")
            default:
                break
            }
        }
    }

    private static func runTool(tool: String, args: [String: Any]) throws -> Any {
        switch tool {
        case "mac_system_snapshot":
            return systemSnapshot()
        case "mac_port_list":
            let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return listPorts(query: query)
        case "mac_window_list":
            return listWindows()
        case "mac_keep_awake":
            let enabled = (args["enabled"] as? Bool) ?? true
            let minutes = (args["minutes"] as? NSNumber)?.intValue ?? 0
            return setKeepAwake(enabled: enabled, minutes: minutes)
        case "mac_port_kill":
            let pid = Int32((args["pid"] as? NSNumber)?.intValue ?? -1)
            let force = (args["force"] as? Bool) ?? false
            return try killPortProcess(pid: pid, force: force)
        case "mac_window_layout":
            let action = (args["action"] as? String) ?? "maximize"
            let appName = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return try arrangeWindow(action: action, appName: appName)
        case "mac_audio_mixer":
            let appName = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let volume = (args["volume"] as? NSNumber)?.doubleValue
            let muted = args["muted"] as? Bool
            return try adjustMixer(appName: appName, volume: volume, muted: muted)
        case "mac_fan_profile":
            let mode = (args["mode"] as? String)?.lowercased() ?? "status"
            return fanProfile(mode: mode)
        default:
            throw NSError(domain: "VorssaintTools", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Unknown tool: \(tool)",
            ])
        }
    }

    private static func systemSnapshot() -> [String: Any] {
        var out: [String: Any] = [:]
        DispatchQueue.main.sync {
            let s = SystemMonitor.shared.snapshot
            if let cpu = s.cpuUsage { out["cpuPercent"] = (cpu * 1000).rounded() / 10 }
            if let gpu = s.gpuUsage { out["gpuPercent"] = (gpu * 1000).rounded() / 10 }
            if let temp = s.cpuTemperature { out["cpuTempC"] = (temp * 10).rounded() / 10 }
            if let gtemp = s.gpuTemperature { out["gpuTempC"] = (gtemp * 10).rounded() / 10 }
            if let used = s.memoryUsed, let total = s.memoryTotal, total > 0 {
                out["memoryUsedBytes"] = used
                out["memoryTotalBytes"] = total
                out["memoryPercent"] = ((Double(used) / Double(total)) * 1000).rounded() / 10
            }
            out["memoryPressure"] = "\(s.memoryPressure)"
            out["fanSpeedsRPM"] = s.fanSpeeds.map { Int($0.rounded()) }
            if let power = s.power {
                out["externalPower"] = power.externalConnected
                if let watts = power.systemWatts { out["systemWatts"] = (watts * 10).rounded() / 10 }
                if let pct = power.chargePercent { out["batteryPercent"] = pct }
            }
            if let down = s.netDownBytesPerSec { out["netDownBytesPerSec"] = Int64(down.rounded()) }
            if let up = s.netUpBytesPerSec { out["netUpBytesPerSec"] = Int64(up.rounded()) }
            if let disk = s.disk?.devices.first(where: { $0.mountPath == "/" }) ?? s.disk?.devices.first(where: \.isInternal) {
                out["diskFreeBytes"] = disk.freeBytes
                out["diskUsedPercent"] = (disk.usedFraction * 1000).rounded() / 10
            }
        }
        return out
    }

    private static func listPorts(query: String) -> [[String: Any]] {
        let result = Shell.run("/usr/sbin/lsof", ["-nP", "+c0", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPT"])
        guard result.status >= 0 else { return [] }
        let entries = PortManagerSupport.parseLsof(result.output)
        return entries.compactMap { entry in
            if !query.isEmpty {
                let hay = "\(entry.port) \(entry.processName) \(entry.pid) \(entry.address)".lowercased()
                guard hay.contains(query) else { return nil }
            }
            return [
                "port": entry.port,
                "pid": Int(entry.pid),
                "process": entry.processName,
                "address": entry.address,
                "protocol": entry.protocolName,
            ]
        }
    }

    private static func listWindows() -> [[String: Any]] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var rows: [[String: Any]] = []
        for win in info {
            let layer = (win[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0,
                  let owner = win[kCGWindowOwnerName as String] as? String, !owner.isEmpty,
                  let pid = win[kCGWindowOwnerPID as String] as? Int else { continue }
            let title = (win[kCGWindowName as String] as? String) ?? ""
            var item: [String: Any] = ["app": owner, "title": title, "pid": pid]
            if let bounds = win[kCGWindowBounds as String] as? [String: Any] {
                item["bounds"] = bounds
            }
            rows.append(item)
            if rows.count >= 40 { break }
        }
        return rows
    }

    private static func setKeepAwake(enabled: Bool, minutes: Int) -> [String: Any] {
        var active = false
        DispatchQueue.main.sync {
            if enabled {
                KeepAwakeManager.shared.activate(minutes: minutes, trigger: .manual)
            } else if KeepAwakeManager.shared.isActive {
                KeepAwakeManager.shared.toggle()
            }
            active = KeepAwakeManager.shared.isActive
        }
        return ["active": active, "minutes": minutes]
    }

    private static func killPortProcess(pid: Int32, force: Bool) throws -> [String: Any] {
        guard pid > 1 else {
            throw NSError(domain: "VorssaintTools", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Refused to terminate system PID \(pid).",
            ])
        }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        let lower = appName.lowercased()
        if lower.contains("baryon") || lower.contains("vorssaint") || lower.contains("hadron") || lower.contains("finder") {
            throw NSError(domain: "VorssaintTools", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Refused to terminate protected process \(appName).",
            ])
        }
        let sig = force ? SIGKILL : SIGTERM
        guard Darwin.kill(pid, sig) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
            ])
        }
        return ["killed": true, "pid": Int(pid), "force": force]
    }

    private static func arrangeWindow(action: String, appName: String?) throws -> [String: Any] {
        var targetPID: pid_t?
        var resolvedApp = ""
        DispatchQueue.main.sync {
            if let appName, !appName.isEmpty {
                let match = NSWorkspace.shared.runningApplications.first {
                    ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
                }
                targetPID = match?.processIdentifier
                resolvedApp = match?.localizedName ?? appName
            } else {
                let front = NSWorkspace.shared.frontmostApplication
                targetPID = front?.processIdentifier
                resolvedApp = front?.localizedName ?? "Frontmost"
            }
        }
        guard let pid = targetPID else {
            throw NSError(domain: "VorssaintTools", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No matching running application found.",
            ])
        }
        let axApp = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard err == .success, let windowElement = focusedRef else {
            throw NSError(domain: "VorssaintTools", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Could not access focused window for \(resolvedApp) (check Accessibility permission).",
            ])
        }
        let axWin = windowElement as! AXUIElement
        var screenFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        DispatchQueue.main.sync {
            if let main = NSScreen.main ?? NSScreen.screens.first {
                let fullHeight = NSScreen.screens.first?.frame.height ?? main.frame.height
                let v = main.visibleFrame
                // Convert Cocoa bottom-left visibleFrame to AX top-left coordinates.
                screenFrame = CGRect(x: v.origin.x, y: fullHeight - (v.origin.y + v.height), width: v.width, height: v.height)
            }
        }
        let rect: CGRect
        switch action.lowercased() {
        case "left":
            rect = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: floor(screenFrame.width / 2), height: screenFrame.height)
        case "right":
            let w = floor(screenFrame.width / 2)
            rect = CGRect(x: screenFrame.maxX - w, y: screenFrame.minY, width: w, height: screenFrame.height)
        case "center":
            let w = floor(screenFrame.width * 0.72)
            let h = floor(screenFrame.height * 0.80)
            rect = CGRect(x: screenFrame.minX + (screenFrame.width - w) / 2, y: screenFrame.minY + (screenFrame.height - h) / 2, width: w, height: h)
        default:
            rect = screenFrame
        }
        var origin = rect.origin
        var size = rect.size
        if let posVal = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
        }
        return ["ok": true, "app": resolvedApp, "action": action]
    }

    private static func adjustMixer(appName: String, volume: Double?, muted: Bool?) throws -> [String: Any] {
        guard !appName.isEmpty else {
            throw NSError(domain: "VorssaintTools", code: 400, userInfo: [NSLocalizedDescriptionKey: "Specify an app name."])
        }
        let lower = appName.lowercased()
        if lower.contains("baryon") || lower.contains("fairy") || lower.contains("lyra") {
            throw NSError(domain: "VorssaintTools", code: 403, userInfo: [NSLocalizedDescriptionKey: "Baryon/Fairy audio cannot be muted or attenuated."])
        }
        var matched: MixerApp?
        DispatchQueue.main.sync {
            let apps = AppVolumeMixer.shared.apps
            matched = apps.first { $0.name.localizedCaseInsensitiveContains(appName) }
            if let app = matched {
                if muted == true {
                    AppVolumeMixer.shared.setVolume(0, for: app)
                } else if muted == false && app.volume <= 0.001 {
                    AppVolumeMixer.shared.setVolume(1.0, for: app)
                }
                if let volume {
                    AppVolumeMixer.shared.setVolume(min(AppVolumeMixer.maxVolume, max(0, volume)), for: app)
                }
            }
        }
        guard let app = matched else {
            throw NSError(domain: "VorssaintTools", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No active audio stream found for '\(appName)'.",
            ])
        }
        return ["app": app.name, "volume": volume ?? app.volume, "muted": muted ?? false]
    }

    private static func fanProfile(mode: String) -> [String: Any] {
        var speeds: [Int] = []
        DispatchQueue.main.sync {
            speeds = SystemMonitor.shared.snapshot.fanSpeeds.map { Int($0.rounded()) }
            if mode == "auto" {
                FanControlService.shared.returnToSystem()
            }
        }
        return ["mode": mode, "fanSpeedsRPM": speeds]
    }
}
