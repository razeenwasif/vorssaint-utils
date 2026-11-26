// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Darwin
import Foundation

/// Two-way sync between Vorssaint's Scratchpad pads and Hadron's Markdown notes
/// (`~/Library/Application Support/dev.flux.browser/md-notes/*.md`), with optional
/// iCloud Drive mirroring (`~/Library/Mobile Documents/com~apple~CloudDocs/BaryonNotes/`).
final class NotesSyncService: ObservableObject {
    static let shared = NotesSyncService()

    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: DefaultsKey.scratchpadICloudSyncEnabled)
            if iCloudSyncEnabled {
                onExternalChange?()
            }
        }
    }
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?

    var onExternalChange: (() -> Void)?

    private let ioQueue = DispatchQueue(label: "com.vorssaint.utils.notes-sync", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?
    private var lastSelfWriteAt: Date = .distantPast

    static var hadronNotesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.flux.browser/md-notes", isDirectory: true)
    }

    static var iCloudNotesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/BaryonNotes", isDirectory: true)
    }

    private init() {
        self.iCloudSyncEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.scratchpadICloudSyncEnabled)
        startWatching()
    }

    deinit {
        watcher?.cancel()
        watcher = nil
    }

    static func safeFileStem(for name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0\n\r")
        let parts = name.components(separatedBy: invalid)
        let joined = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = joined.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return stripped.isEmpty ? "Note" : stripped
    }

    static func noteURL(for padName: String, in directory: URL) -> URL {
        directory.appendingPathComponent(safeFileStem(for: padName) + ".md")
    }

    func syncWithDisk(document: ScratchpadDocument) -> (document: ScratchpadDocument, changed: Bool) {
        let fm = FileManager.default
        let hadronDir = Self.hadronNotesURL
        try? fm.createDirectory(at: hadronDir, withIntermediateDirectories: true)

        if iCloudSyncEnabled {
            syncICloudMirrorWithHadron(hadronDir: hadronDir, iCloudDir: Self.iCloudNotesURL)
        }

        let diskEntries = Self.scanMarkdownFiles(in: hadronDir, coordinated: false)
        var byLowerStem: [String: (url: URL, stem: String, text: String, modifiedAt: Date)] = [:]
        for entry in diskEntries {
            byLowerStem[entry.stem.lowercased()] = entry
        }

        var next = document
        var changed = false

        // 1. Reconcile existing pads with disk notes.
        for index in next.pads.indices {
            let pad = next.pads[index]
            let stem = Self.safeFileStem(for: pad.name)
            let key = stem.lowercased()
            if let disk = byLowerStem[key] {
                let padDate = pad.modifiedAt ?? .distantPast
                if disk.modifiedAt.timeIntervalSince(padDate) > 1.5, disk.text != pad.text {
                    next.pads[index].text = disk.text
                    next.pads[index].modifiedAt = disk.modifiedAt
                    changed = true
                } else if !pad.text.isEmpty,
                          padDate.timeIntervalSince(disk.modifiedAt) > 1.5 || (pad.modifiedAt != nil && pad.text != disk.text && padDate >= disk.modifiedAt) {
                    writePadText(pad.text, to: disk.url, modifiedAt: pad.modifiedAt)
                    if iCloudSyncEnabled {
                        mirrorToICloud(stem: stem, text: pad.text, modifiedAt: pad.modifiedAt)
                    }
                }
            } else if !pad.text.isEmpty {
                let url = Self.noteURL(for: pad.name, in: hadronDir)
                writePadText(pad.text, to: url, modifiedAt: pad.modifiedAt)
                if iCloudSyncEnabled {
                    mirrorToICloud(stem: stem, text: pad.text, modifiedAt: pad.modifiedAt)
                }
            }
        }

        // 2. Import new `.md` notes from Hadron (never delete extra files on disk if at pad limit).
        let existingKeys = Set(next.pads.map { Self.safeFileStem(for: $0.name).lowercased() })
        let unmapped = diskEntries
            .filter { !existingKeys.contains($0.stem.lowercased()) }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        if !unmapped.isEmpty {
            let onlyUntouchedDefault = next.pads.count == 1
                && next.pads[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && next.pads[0].modifiedAt == nil

            if onlyUntouchedDefault, let first = unmapped.first {
                let name = String(first.stem.prefix(ScratchpadDocument.maximumNameLength))
                let replacement = ScratchpadPad(
                    id: UUID(),
                    name: name.isEmpty ? "Note" : name,
                    text: first.text,
                    modifiedAt: first.modifiedAt
                )
                next.pads = [replacement]
                next.selectedID = replacement.id
                changed = true
                for extra in unmapped.dropFirst() where next.pads.count < ScratchpadDocument.maximumPadCount {
                    let extraName = String(extra.stem.prefix(ScratchpadDocument.maximumNameLength))
                    next.pads.append(ScratchpadPad(
                        id: UUID(),
                        name: extraName.isEmpty ? "Note" : extraName,
                        text: extra.text,
                        modifiedAt: extra.modifiedAt
                    ))
                }
            } else {
                for extra in unmapped where next.pads.count < ScratchpadDocument.maximumPadCount {
                    let extraName = String(extra.stem.prefix(ScratchpadDocument.maximumNameLength))
                    next.pads.append(ScratchpadPad(
                        id: UUID(),
                        name: extraName.isEmpty ? "Note" : extraName,
                        text: extra.text,
                        modifiedAt: extra.modifiedAt
                    ))
                    changed = true
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastSyncedAt = Date()
            self?.lastError = nil
        }
        return (next, changed)
    }

    func exportPadToDisk(_ pad: ScratchpadPad, previousName: String? = nil) {
        let hadronDir = Self.hadronNotesURL
        let iCloudDir = Self.iCloudNotesURL
        let iCloudEnabled = iCloudSyncEnabled
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: hadronDir, withIntermediateDirectories: true)

            if let previousName, Self.safeFileStem(for: previousName) != Self.safeFileStem(for: pad.name) {
                let oldURL = Self.noteURL(for: previousName, in: hadronDir)
                let newURL = Self.noteURL(for: pad.name, in: hadronDir)
                if fm.fileExists(atPath: oldURL.path) {
                    self.lastSelfWriteAt = Date()
                    try? fm.moveItem(at: oldURL, to: newURL)
                }
                if iCloudEnabled {
                    let oldCloud = Self.noteURL(for: previousName, in: iCloudDir)
                    let newCloud = Self.noteURL(for: pad.name, in: iCloudDir)
                    if fm.fileExists(atPath: oldCloud.path) {
                        Self.coordinate {
                            try? fm.moveItem(at: oldCloud, to: newCloud)
                        }
                    }
                }
            }

            let targetURL = Self.noteURL(for: pad.name, in: hadronDir)
            if !pad.text.isEmpty || fm.fileExists(atPath: targetURL.path) {
                self.writePadText(pad.text, to: targetURL, modifiedAt: pad.modifiedAt)
                if iCloudEnabled {
                    self.mirrorToICloud(stem: Self.safeFileStem(for: pad.name), text: pad.text, modifiedAt: pad.modifiedAt)
                }
            }
            DispatchQueue.main.async {
                self.lastSyncedAt = Date()
            }
        }
    }

    private func writePadText(_ text: String, to url: URL, modifiedAt: Date?) {
        lastSelfWriteAt = Date()
        guard let data = text.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if let modifiedAt {
            try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func mirrorToICloud(stem: String, text: String, modifiedAt: Date?) {
        let dir = Self.iCloudNotesURL
        let url = dir.appendingPathComponent(stem + ".md")
        guard let data = text.data(using: .utf8) else { return }
        Self.coordinate(writingTo: url) { target in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
            if let modifiedAt {
                try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: target.path)
            }
        }
    }

    private func syncICloudMirrorWithHadron(hadronDir: URL, iCloudDir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: iCloudDir.deletingLastPathComponent().path) else { return }
        try? fm.createDirectory(at: iCloudDir, withIntermediateDirectories: true)

        let hadronFiles = Self.scanMarkdownFiles(in: hadronDir, coordinated: false)
        let cloudFiles = Self.scanMarkdownFiles(in: iCloudDir, coordinated: true)

        let hadronByKey = Dictionary(uniqueKeysWithValues: hadronFiles.map { ($0.stem.lowercased(), $0) })
        let cloudByKey = Dictionary(uniqueKeysWithValues: cloudFiles.map { ($0.stem.lowercased(), $0) })

        for cloud in cloudFiles {
            let key = cloud.stem.lowercased()
            if let local = hadronByKey[key] {
                if cloud.modifiedAt.timeIntervalSince(local.modifiedAt) > 1.5, cloud.text != local.text {
                    writePadText(cloud.text, to: local.url, modifiedAt: cloud.modifiedAt)
                }
            } else {
                let target = hadronDir.appendingPathComponent(cloud.stem + ".md")
                writePadText(cloud.text, to: target, modifiedAt: cloud.modifiedAt)
            }
        }

        for local in hadronFiles {
            let key = local.stem.lowercased()
            let cloud = cloudByKey[key]
            if cloud == nil || (local.modifiedAt.timeIntervalSince(cloud!.modifiedAt) > 1.5 && local.text != cloud!.text) {
                mirrorToICloud(stem: local.stem, text: local.text, modifiedAt: local.modifiedAt)
            }
        }
    }

    private static func scanMarkdownFiles(in directory: URL, coordinated: Bool) -> [(url: URL, stem: String, text: String, modifiedAt: Date)] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(url: URL, stem: String, text: String, modifiedAt: Date)] = []
        for url in urls {
            let filename = url.lastPathComponent
            guard !filename.hasPrefix("."),
                  !filename.hasSuffix(".icloud"),
                  url.pathExtension.lowercased() == "md" else {
                continue
            }
            var loadedText: String?
            var modDate: Date = Date()
            if coordinated {
                coordinate(readingFrom: url) { coordURL in
                    loadedText = try? String(contentsOf: coordURL, encoding: .utf8)
                    let vals = try? coordURL.resourceValues(forKeys: [.contentModificationDateKey])
                    if let d = vals?.contentModificationDate { modDate = d }
                }
            } else {
                loadedText = try? String(contentsOf: url, encoding: .utf8)
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if let d = vals?.contentModificationDate { modDate = d }
            }
            guard let text = loadedText else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            results.append((url: url, stem: stem, text: text, modifiedAt: modDate))
        }
        return results
    }

    private static func coordinate(readingFrom url: URL, block: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var err: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &err) { coordURL in
            block(coordURL)
        }
    }

    private static func coordinate(writingTo url: URL, block: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var err: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &err) { coordURL in
            block(coordURL)
        }
    }

    private static func coordinate(_ block: () -> Void) {
        block()
    }

    private func startWatching() {
        let dir = Self.hadronNotesURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSelfWriteAt) < 1.0 { return }
            self.reloadWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async {
                    self?.onExternalChange?()
                }
            }
            self.reloadWorkItem = work
            self.ioQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        watcher = source
        source.resume()
    }
}
