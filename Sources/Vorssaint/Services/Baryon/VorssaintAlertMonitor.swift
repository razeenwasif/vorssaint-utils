// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Watches `SystemMonitor.shared.$snapshot` for sustained CPU, RAM pressure, or thermal
/// spikes (>= 20s continuous) and emits `vorssaint.alert` over `vorssaint.sock` with cooldown.
final class VorssaintAlertMonitor {
    static let shared = VorssaintAlertMonitor()

    private var subscription: AnyCancellable?
    private var spikeStart: [String: Date] = [:]
    private var lastAlertAt: [String: Date] = [:]
    private let sustainedThreshold: TimeInterval = 20
    private let cooldown: TimeInterval = 600

    private init() {}

    func start() {
        guard subscription == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.subscription == nil else { return }
            self.subscription = SystemMonitor.shared.$snapshot
                .sink { [weak self] snapshot in
                    self?.evaluate(snapshot)
                }
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        spikeStart.removeAll()
    }

    private func evaluate(_ snapshot: SystemSnapshot) {
        let now = Date()

        let cpuHigh = (snapshot.cpuUsage ?? 0) >= 0.90
        track(
            kind: "cpu_high",
            active: cpuHigh,
            now: now,
            title: "High CPU Load",
            detail: snapshot.cpuUsage.map { "CPU sustained at \(Int(($0 * 100).rounded()))%" } ?? "CPU load elevated",
            metrics: ["cpuPercent": ((snapshot.cpuUsage ?? 0) * 100).rounded()]
        )

        let memCritical = snapshot.memoryPressure == .critical
        track(
            kind: "memory_critical",
            active: memCritical,
            now: now,
            title: "Critical Memory Pressure",
            detail: "macOS memory pressure reached critical threshold",
            metrics: ["pressure": "critical"]
        )

        let tempHigh = (snapshot.cpuTemperature ?? 0) >= 95.0
        track(
            kind: "thermal_high",
            active: tempHigh,
            now: now,
            title: "High Thermal Warning",
            detail: snapshot.cpuTemperature.map { String(format: "CPU temperature at %.1f°C", $0) } ?? "CPU hot",
            metrics: ["cpuTempC": snapshot.cpuTemperature ?? 0]
        )
    }

    private func track(kind: String, active: Bool, now: Date, title: String, detail: String, metrics: [String: Any]) {
        guard active else {
            spikeStart.removeValue(forKey: kind)
            return
        }
        let started = spikeStart[kind] ?? now
        if spikeStart[kind] == nil {
            spikeStart[kind] = started
            return
        }
        guard now.timeIntervalSince(started) >= sustainedThreshold else { return }
        if let prev = lastAlertAt[kind], now.timeIntervalSince(prev) < cooldown { return }
        lastAlertAt[kind] = now
        BaryonBridgeService.shared.sendSystemAlert(kind: kind, title: title, detail: detail, metrics: metrics)
    }
}
