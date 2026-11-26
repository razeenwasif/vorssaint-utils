// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Runtime helper configuration and pruned feature table when Vorssaint runs
/// alongside or inside Baryon (`--baryon-helper`).
enum BaryonHelperMode {
    static let excludedBundleIdentifiers: Set<String> = [
        "dev.razeen.lyra",
        "dev.flux.browser",
    ]

    static let prunedFeatures: Set<AppFeature> = [
        .autoQuit, .quitWindowProtection, .wallpaper, .cleaningMode,
        .diskImageInstaller, .urlCleaner, .finderCutPaste, .finderRename,
        .appUpdates, .homebrew, .uninstaller, .cleaner, .mediaTools, .quitApps,
        .dockClick, .spacesOrder, .musicBlock, .bluetoothSleep,
        .scrollInverter, .scrollHorizontal, .scrollZoom, .focusFollowsMouse,
        .smoothScroll, .linearScroll, .scrollSpeed, .mouseAcceleration,
        .mouseNavigation, .mouseButtonShortcuts, .middleClick,
        .mouseClickDebounce, .keyboardDebounce, .superKey,
        .notchDownloads, .notchQueue, .notchAccessories, .notchWatch,
    ]

    static var isEnabled: Bool {
        CommandLine.arguments.contains("--baryon-helper")
            || ProcessInfo.processInfo.environment["BARYON_HELPER"] == "1"
    }

    static var socketPath: String {
        if let idx = CommandLine.arguments.firstIndex(of: "--socket"),
           idx + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[idx + 1]
        }
        if let env = ProcessInfo.processInfo.environment["BARYON_VORSSAINT_SOCK"], !env.isEmpty {
            return env
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("lyra-companion/lyra/vorssaint.sock").path
    }

    static var keptFeatures: [AppFeature] {
        AppFeature.allCases.filter { !prunedFeatures.contains($0) }
    }

    private static let defaultsBootstrappedKey = "baryonHelperDefaultsBootstrappedV1"

    static let defaultAvailableFeatures: [AppFeature] = [
        .notch, .notchMascot, .notchCalendar, .notchAgents, .notchNotifications,
        .notchGestures, .notchTimer, .notchLyrics, .notchLiveEqualizer,
        .commandBar, .radialMenu, .shelf, .clipboardHistory, .scratchpad,
        .screenshot, .screenOCR, .screenRecorder, .quickLauncher, .quickToggles,
        .portManager, .killProcess, .mixer, .keepAwake,
        .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork,
        .monitorDisk, .monitorPower,
    ]

    static func bootstrapDefaultsIfNeeded(in defaults: UserDefaults = .standard) {
        guard isEnabled, !defaults.bool(forKey: defaultsBootstrappedKey) else { return }

        let prunedAvailabilityKeys = Set(prunedFeatures.map(\.availabilityKey))
        for domain in ["com.vorssaint.utils.dev", "com.vorssaint.utils"] {
            guard let legacy = UserDefaults(suiteName: domain)?.persistentDomain(forName: domain),
                  !legacy.isEmpty else {
                continue
            }
            for (key, value) in legacy {
                if key == DefaultsKey.baryonUnifiedTray { continue }
                if prunedAvailabilityKeys.contains(key) { continue }
                defaults.set(value, forKey: key)
            }
            break
        }

        defaults.set(true, forKey: DefaultsKey.hasOnboarded)
        for feature in defaultAvailableFeatures {
            defaults.set(true, forKey: feature.availabilityKey)
        }
        for feature in prunedFeatures {
            defaults.set(false, forKey: feature.availabilityKey)
        }
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        defaults.set(true, forKey: DefaultsKey.notchMascotEnabled)
        if defaults.string(forKey: DefaultsKey.notchMascotStyle) == nil {
            defaults.set(NotchMascotStyle.fairy.rawValue, forKey: DefaultsKey.notchMascotStyle)
        }
        defaults.set(true, forKey: defaultsBootstrappedKey)
    }

    static var storageIdentifier: String? {
        Bundle.main.bundleIdentifier ?? (isEnabled ? "baryon-vorssaint" : nil)
    }

    private static let privateStoreMigratedKey = "baryonHelperPrivateStoreMigratedV1"

    static func migratePrivateStoreIfNeeded(in defaults: UserDefaults = .standard) {
        guard isEnabled,
              !defaults.bool(forKey: privateStoreMigratedKey),
              let targetDir = PrivateFileStore.containerURL,
              let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let fm = FileManager.default
        guard PrivateFileStore.createDirectory(at: targetDir) else { return }

        let items = ["Scratchpad.json", "ClipboardHistory.json", "ClipboardImages", "agent-prices.json"]
        if let legacyDir = ["com.vorssaint.utils.dev", "com.vorssaint.utils"]
            .map({ appSupport.appendingPathComponent($0, isDirectory: true) })
            .first(where: { dir in
                fm.fileExists(atPath: dir.appendingPathComponent("Scratchpad.json").path)
                    || fm.fileExists(atPath: dir.appendingPathComponent("ClipboardHistory.json").path)
            }) {
            for item in items {
                let src = legacyDir.appendingPathComponent(item)
                let dst = targetDir.appendingPathComponent(item)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                try? fm.copyItem(at: src, to: dst)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dst.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dst.path)
                        if let children = try? fm.subpathsOfDirectory(atPath: dst.path) {
                            for rel in children {
                                let childPath = dst.appendingPathComponent(rel).path
                                var childIsDir: ObjCBool = false
                                fm.fileExists(atPath: childPath, isDirectory: &childIsDir)
                                try? fm.setAttributes([.posixPermissions: childIsDir.boolValue ? 0o700 : 0o600],
                                                      ofItemAtPath: childPath)
                            }
                        }
                    } else {
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
                    }
                }
            }
        }

        defaults.set(true, forKey: privateStoreMigratedKey)
    }
}
