// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Darwin
import Foundation

struct HadronTodoItem: Codable, Equatable, Identifiable {
    var id: Int64
    var title: String
    var done: Bool
    var created_ms: Int64
    var due: String
    var profile: String
    var updated_ms: Int64
    var time: String
    var priority: Int
    var minutes: Int
    var source: String
    var by_agent: Bool

    init(
        id: Int64,
        title: String,
        done: Bool = false,
        created_ms: Int64,
        due: String = "",
        profile: String = "Personal",
        updated_ms: Int64,
        time: String = "",
        priority: Int = 0,
        minutes: Int = 0,
        source: String = "vorssaint",
        by_agent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.done = done
        self.created_ms = created_ms
        self.due = due
        self.profile = profile
        self.updated_ms = updated_ms
        self.time = time
        self.priority = priority
        self.minutes = minutes
        self.source = source
        self.by_agent = by_agent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        created_ms = try c.decodeIfPresent(Int64.self, forKey: .created_ms) ?? nowMs
        due = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? "Personal"
        updated_ms = try c.decodeIfPresent(Int64.self, forKey: .updated_ms) ?? created_ms
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        by_agent = try c.decodeIfPresent(Bool.self, forKey: .by_agent) ?? false
    }
}

struct HadronTodoFile: Codable, Equatable {
    var items: [HadronTodoItem]
}

enum HadronTodoShorthandParser {
    struct Parsed {
        let title: String
        let due: String
        let time: String
        let priority: Int
        let minutes: Int
    }

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Parsed? {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var titleTokens: [String] = []
        var due = ""
        var time = ""
        var priority = 0
        var minutes = 0

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = calendar.timeZone
        dayFmt.dateFormat = "yyyy-MM-dd"

        for token in tokens {
            let lower = token.lowercased()

            if priority == 0, let p = parsePriority(lower) {
                priority = p
                continue
            }
            if minutes == 0, let mins = parseDuration(lower) {
                minutes = mins
                continue
            }
            if time.isEmpty, let parsedTime = parseTime(lower) {
                time = parsedTime
                continue
            }
            if due.isEmpty, let parsedDue = parseDueDate(lower, now: now, calendar: calendar, formatter: dayFmt) {
                due = parsedDue
                continue
            }
            titleTokens.append(token)
        }

        let cleanTitle = titleTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        return Parsed(title: cleanTitle, due: due, time: time, priority: priority, minutes: minutes)
    }

    private static func parsePriority(_ token: String) -> Int? {
        switch token {
        case "!1": return 1
        case "!2": return 2
        case "!3": return 3
        default: return nil
        }
    }

    private static func parseDuration(_ token: String) -> Int? {
        guard token.hasPrefix("~") else { return nil }
        let body = String(token.dropFirst())
        if body.hasSuffix("m"), let n = Int(body.dropLast()), n > 0, n <= 720 {
            return n
        }
        if body.hasSuffix("h"), let n = Double(body.dropLast()), n > 0, n <= 12 {
            return Int((n * 60.0).rounded())
        }
        return nil
    }

    private static func parseTime(_ token: String) -> String? {
        if let ampm = token.range(of: #"^(\d{1,2})(?::(\d{2}))?(am|pm)$"#, options: .regularExpression) {
            let str = String(token[ampm])
            let isPM = str.hasSuffix("pm")
            let core = String(str.dropLast(2))
            let parts = core.split(separator: ":").map(String.init)
            guard var hour = Int(parts[0]), (1...12).contains(hour) else { return nil }
            let minute = parts.count > 1 ? (Int(parts[1]) ?? -1) : 0
            guard (0...59).contains(minute) else { return nil }
            if hour == 12 { hour = isPM ? 12 : 0 } else if isPM { hour += 12 }
            return String(format: "%02d:%02d", hour, minute)
        }
        if token.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
            let parts = token.split(separator: ":").map(String.init)
            guard let hour = Int(parts[0]), (0...23).contains(hour),
                  let minute = Int(parts[1]), (0...59).contains(minute) else { return nil }
            return String(format: "%02d:%02d", hour, minute)
        }
        return nil
    }

    private static func parseDueDate(_ token: String, now: Date, calendar: Calendar, formatter: DateFormatter) -> String? {
        if token.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           formatter.date(from: token) != nil {
            return token
        }
        let today = calendar.startOfDay(for: now)
        if token == "today" {
            return formatter.string(from: today)
        }
        if token == "tomorrow" || token == "tmr" {
            guard let d = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return formatter.string(from: d)
        }
        let weekdays: [String: Int] = [
            "sun": 1, "sunday": 1,
            "mon": 2, "monday": 2,
            "tue": 3, "tues": 3, "tuesday": 3,
            "wed": 4, "wednesday": 4,
            "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
            "fri": 6, "friday": 6,
            "sat": 7, "saturday": 7,
        ]
        guard let targetWeekday = weekdays[token] else { return nil }
        let currentWeekday = calendar.component(.weekday, from: today)
        var delta = (targetWeekday - currentWeekday + 7) % 7
        if delta == 0 { delta = 7 }
        guard let d = calendar.date(byAdding: .day, value: delta, to: today) else { return nil }
        return formatter.string(from: d)
    }
}

/// Two-way conflict-safe store syncing with Hadron's `todos.json` via
/// directory-level DispatchSource watching + atomic tmp->rename writes.
final class HadronTodoSyncService: ObservableObject {
    static let shared = HadronTodoSyncService()

    @Published private(set) var items: [HadronTodoItem] = []
    @Published var selectedProfile: String = "All"
    @Published private(set) var lastSyncError: String?

    private let ioQueue = DispatchQueue(label: "com.vorssaint.utils.hadron-todos", qos: .utility)
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var watchedDirFD: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?
    private var tombstones: [Int64: Int64] = [:]

    static var todosDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.flux.browser", isDirectory: true)
    }

    static var todosFileURL: URL {
        todosDirectoryURL.appendingPathComponent("todos.json")
    }

    private init() {
        reloadFromDisk()
        startWatching()
    }

    deinit {
        dirWatcher?.cancel()
        dirWatcher = nil
    }

    var profiles: [String] {
        let found = Set(items.map { $0.profile.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let sorted = (found.isEmpty ? ["Personal"] : Array(found)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return ["All"] + sorted
    }

    var filteredItems: [HadronTodoItem] {
        let base = selectedProfile == "All"
            ? items
            : items.filter { $0.profile.caseInsensitiveCompare(selectedProfile) == .orderedSame }
        return base.sorted { lhs, rhs in
            if lhs.done != rhs.done { return !lhs.done }
            if !lhs.done {
                let lp = lhs.priority > 0 ? lhs.priority : 99
                let rp = rhs.priority > 0 ? rhs.priority : 99
                if lp != rp { return lp < rp }
                if lhs.due != rhs.due {
                    if lhs.due.isEmpty { return false }
                    if rhs.due.isEmpty { return true }
                    return lhs.due < rhs.due
                }
            }
            return lhs.updated_ms > rhs.updated_ms
        }
    }

    func reloadFromDisk() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = Self.readDiskItems()
            DispatchQueue.main.async {
                self.items = loaded
                self.lastSyncError = nil
            }
        }
    }

    func toggleDone(id: Int64) {
        let nowMs = Self.nowMs()
        mutateAndPersist { current in
            guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
            current[idx].done.toggle()
            current[idx].updated_ms = nowMs
        }
    }

    func addTask(rawInput: String, profile: String? = nil) {
        let targetProfile: String = {
            if let profile, !profile.isEmpty, profile != "All" { return profile }
            if selectedProfile != "All" { return selectedProfile }
            return "Personal"
        }()
        guard let parsed = HadronTodoShorthandParser.parse(rawInput) else { return }
        let nowMs = Self.nowMs()
        mutateAndPersist { current in
            let nextID = (current.map(\.id).max() ?? 0) + 1
            let newItem = HadronTodoItem(
                id: nextID,
                title: parsed.title,
                done: false,
                created_ms: nowMs,
                due: parsed.due,
                profile: targetProfile,
                updated_ms: nowMs,
                time: parsed.time,
                priority: parsed.priority,
                minutes: parsed.minutes,
                source: "vorssaint",
                by_agent: false
            )
            current.append(newItem)
        }
    }

    func deleteTask(id: Int64) {
        let nowMs = Self.nowMs()
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.tombstones[id] = nowMs
        }
        mutateAndPersist { current in
            current.removeAll { $0.id == id }
        }
    }

    func promoteToFairyGoal(_ item: HadronTodoItem) {
        var details: [String] = [item.title]
        if !item.profile.isEmpty { details.append("Profile: \(item.profile)") }
        if !item.due.isEmpty {
            details.append("Due: \(item.due)\(item.time.isEmpty ? "" : " \(item.time)")")
        }
        if item.minutes > 0 { details.append("Est: \(item.minutes)m") }
        let payload = details.joined(separator: "\n")
        let sent = BaryonBridgeService.shared.sendContextAction(
            action: "goal",
            text: payload,
            source: "tasks"
        )
        if !sent {
            DispatchQueue.main.async { [weak self] in
                self?.lastSyncError = "Baryon is offline — connect Baryon to start a Fairy goal."
            }
        }
    }

    private func mutateAndPersist(_ transform: @escaping (inout [HadronTodoItem]) -> Void) {
        let snapshot = items
        ioQueue.async { [weak self] in
            guard let self else { return }
            let diskItems = Self.readDiskItems()
            var merged = Self.merge(local: snapshot, disk: diskItems, tombstones: self.tombstones)
            transform(&merged)
            do {
                try Self.writeAtomically(items: merged)
                // Clear tombstones for items no longer on disk.
                let diskIDs = Set(merged.map(\.id))
                self.tombstones = self.tombstones.filter { diskIDs.contains($0.key) }
                DispatchQueue.main.async {
                    self.items = merged
                    self.lastSyncError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastSyncError = error.localizedDescription
                }
            }
        }
    }

    private static func merge(local: [HadronTodoItem], disk: [HadronTodoItem], tombstones: [Int64: Int64]) -> [HadronTodoItem] {
        var byID: [Int64: HadronTodoItem] = [:]
        for item in disk {
            if let deletedAt = tombstones[item.id], deletedAt >= item.updated_ms {
                continue
            }
            byID[item.id] = item
        }
        for item in local {
            if let deletedAt = tombstones[item.id], deletedAt >= item.updated_ms {
                continue
            }
            if let existing = byID[item.id] {
                if item.updated_ms >= existing.updated_ms {
                    byID[item.id] = item
                }
            } else {
                byID[item.id] = item
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func readDiskItems() -> [HadronTodoItem] {
        let url = todosFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let decoded = try? JSONDecoder().decode(HadronTodoFile.self, from: data) else {
            return []
        }
        return decoded.items
    }

    private static func writeAtomically(items: [HadronTodoItem]) throws {
        let dir = todosDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = todosFileURL
        let temp = dir.appendingPathComponent("todos.json.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(HadronTodoFile(items: items))
        try data.write(to: temp, options: .atomic)
        if Darwin.rename(temp.path, target.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
            ])
        }
    }

    private func startWatching() {
        let dir = Self.todosDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        dirWatcher = source
        source.resume()
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let disk = Self.readDiskItems()
            DispatchQueue.main.async {
                self.items = disk
            }
        }
        reloadWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
