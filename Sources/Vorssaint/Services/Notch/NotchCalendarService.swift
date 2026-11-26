// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import EventKit

/// EventKit objects stay on one actor; only immutable display values reach UI.
private actor NotchCalendarReader {
    private lazy var store = EKEventStore()

    func read(interval: DateInterval, excluded: Set<String>) -> [NotchCalendarEvent] {
        guard !Task.isCancelled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let calendars = NotchCalendarSupport.calendarsToRead(store.calendars(for: .event), excluded: excluded,
                                                             identifier: \.calendarIdentifier)
        if calendars?.isEmpty == true { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled,
                  event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) != true,
                  let identifier = event.eventIdentifier,
                  let start = event.startDate, let end = event.endDate else { return nil }
            let recurring = event.hasRecurrenceRules || event.isDetached
            let countdownKey = NotchCalendarSupport.countdownKey(
                identifier: identifier, occurrence: recurring ? event.occurrenceDate ?? start : nil)
            return NotchCalendarEvent(id: identifier + ":" + String(start.timeIntervalSinceReferenceDate),
                                      title: event.title ?? "", calendar: event.calendar.title,
                                      start: start, end: end, allDay: event.isAllDay,
                                      location: event.location ?? "", color: Self.tint(event.calendar),
                                      calendarItemIdentifier: event.calendarItemIdentifier,
                                      recurring: recurring, countdownKey: countdownKey)
        }
    }

    func calendars() -> [NotchCalendarChoice] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return store.calendars(for: .event).map {
            NotchCalendarChoice(id: $0.calendarIdentifier, title: $0.title,
                                sourceID: $0.source?.sourceIdentifier ?? "", source: $0.source?.title ?? "",
                                color: Self.tint($0))
        }
    }

    private static func tint(_ calendar: EKCalendar) -> NotchCalendarColor {
        let color = calendar.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        return color.map { NotchCalendarColor(red: $0.redComponent, green: $0.greenComponent,
                                              blue: $0.blueComponent) } ?? .fallback
    }
}

/// Owned by the notch lifecycle, including sleep and lock. No event text is
/// persisted; events chosen for the countdown are kept by identifier only.
final class NotchCalendarService: NSObject, ObservableObject {
    static let shared = NotchCalendarService()
    @Published private(set) var events: [NotchCalendarEvent] = []
    @Published private(set) var countdown: NotchCalendarCountdown?
    @Published private(set) var loading = false
    /// The event the Calendar page scrolls to once, after a click on the countdown.
    @Published var revealing: String?
    /// Countdown keys of the events chosen from their menu.
    @Published private(set) var chosenCountdowns = Set<String>()
    @Published private(set) var googleCalendarConnected = false
    var hasGoogleCalendar: Bool { googleCalendarConnected || !cachedGoogleEvents.isEmpty }

    private struct GoogleCalendarCache: Codable {
        let connected: Bool
        let events: [BaryonCalendarEvent]
    }

    private var cachedGoogleEvents: [BaryonCalendarEvent] = []
    private var reader: NotchCalendarReader?
    private var task: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var permissionSubscription: AnyCancellable?
    private var generation = UUID()
    private var visibleMonth: Date?
    private var countdownEnabled = false
    private var timeLeftEnabled = false
    /// How long before a start the island counts down, from Settings.
    private(set) var countdownLeadTime = NotchCalendarSupport.countdownLeadTime()
    private var excludedCalendars = Set<String>()

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vorssaint/google-calendar-cache.json")
    }

    private override init() {
        super.init()
        loadGoogleCache()
    }

    private func loadGoogleCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(GoogleCalendarCache.self, from: data) else { return }
        cachedGoogleEvents = cache.events
        googleCalendarConnected = cache.connected
    }

    private func saveGoogleCache() {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cache = GoogleCalendarCache(connected: googleCalendarConnected, events: cachedGoogleEvents)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func applyGoogleCalendarEvents(_ events: [BaryonCalendarEvent], connected: Bool) {
        googleCalendarConnected = connected
        cachedGoogleEvents = events
        saveGoogleCache()
        if reader != nil {
            refresh()
        } else if NotchCalendarSupport.isEnabled() {
            syncWithPreferences()
        }
    }

    /// Every event calendar on this Mac, for the Settings list. Works while
    /// the island's reader is stopped, since the list is edited from Settings.
    func calendarChoices() async -> [NotchCalendarChoice] {
        await (reader ?? NotchCalendarReader()).calendars()
    }

    func isChosen(_ event: NotchCalendarEvent) -> Bool {
        NotchCalendarSupport.isChosen(event, in: chosenCountdowns)
    }

    /// Counts down to one event, or stops, whatever the countdown for every event does.
    func setCountdown(_ chosen: Bool, for event: NotchCalendarEvent) {
        NotchCalendarSupport.setCountdown(chosen, for: event)
        let keys = Set(NotchCalendarSupport.chosenCountdowns().keys)
        guard keys != chosenCountdowns else { return }
        chosenCountdowns = keys
        if let countdown, !follows(countdown) { self.countdown = nil }
        refresh()
    }

    private func follows(_ countdown: NotchCalendarCountdown) -> Bool {
        countdown.ongoing ? timeLeftEnabled : countdownEnabled || isChosen(countdown.event)
    }

    func showMonth(_ month: Date?) {
        visibleMonth = month
        events = []
        refresh()
    }

    func syncWithPreferences() {
        guard NotchCalendarSupport.isEnabled() else { stop(); return }
        let countdownEnabled = NotchCalendarSupport.showsCountdown()
        let timeLeftEnabled = NotchCalendarSupport.showsTimeLeft()
        let countdownLeadTime = NotchCalendarSupport.countdownLeadTime()
        let excludedCalendars = NotchCalendarSupport.excludedCalendars()
        let chosenCountdowns = Set(NotchCalendarSupport.chosenCountdowns().keys)
        guard reader == nil else {
            if self.countdownEnabled != countdownEnabled || self.timeLeftEnabled != timeLeftEnabled
                || self.countdownLeadTime != countdownLeadTime || self.excludedCalendars != excludedCalendars
                || self.chosenCountdowns != chosenCountdowns {
                if !excludedCalendars.isSubset(of: self.excludedCalendars) {
                    events = []
                    countdown = nil
                }
                self.countdownEnabled = countdownEnabled
                self.timeLeftEnabled = timeLeftEnabled
                self.countdownLeadTime = countdownLeadTime
                self.excludedCalendars = excludedCalendars
                if self.chosenCountdowns != chosenCountdowns { self.chosenCountdowns = chosenCountdowns }
                if let countdown, !follows(countdown) { self.countdown = nil }
                refresh()
            }
            return
        }
        self.countdownEnabled = countdownEnabled
        self.timeLeftEnabled = timeLeftEnabled
        self.countdownLeadTime = countdownLeadTime
        self.excludedCalendars = excludedCalendars
        if self.chosenCountdowns != chosenCountdowns { self.chosenCountdowns = chosenCountdowns }
        reader = NotchCalendarReader()
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification,
                     .NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refresh()
            })
        }
        permissionSubscription = Permissions.shared.$calendarAccess.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.refresh() }
        BaryonBridgeService.shared.requestCalendarEvents()
        refresh()
    }

    func refresh() {
        task?.cancel()
        refreshTimer?.invalidate(); refreshTimer = nil
        generation = UUID()
        guard NotchCalendarSupport.isEnabled(), let reader else { stop(); return }
        let hasApple = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasApple || hasGoogleCalendar else {
            events = []; countdown = nil; loading = false
            return
        }
        let requested = generation
        let now = Date()
        let interval = NotchCalendarSupport.readInterval(month: visibleMonth, now: now)
        let currentInterval = NotchCalendarSupport.readInterval(month: nil, now: now)
        let needsCurrentRead = NotchCalendarSupport.needsCurrentRead(
            visible: interval, current: currentInterval,
            countdownEnabled: countdownEnabled || timeLeftEnabled || !chosenCountdowns.isEmpty)
        let excluded = excludedCalendars
        let googleSnapshot = Self.mappedGoogleEvents(cachedGoogleEvents)
        loading = events.isEmpty
        task = Task { @MainActor [weak self] in
            let appleResult = hasApple ? await reader.read(interval: interval, excluded: excluded) : []
            let appleCurrent = hasApple
                ? (needsCurrentRead ? await reader.read(interval: currentInterval, excluded: excluded) : appleResult)
                : []
            guard !Task.isCancelled, let self, self.generation == requested,
                  NotchCalendarSupport.isEnabled() else { return }
            let now = Date()
            let nowApple = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            guard nowApple || self.hasGoogleCalendar else {
                self.events = []; self.countdown = nil; self.loading = false; self.task = nil
                return
            }
            let mergedVisible = Self.mergeEvents(apple: nowApple ? appleResult : [], google: googleSnapshot, interval: interval)
            self.events = NotchCalendarSupport.ordered(mergedVisible)
            let currentEvents = needsCurrentRead
                ? NotchCalendarSupport.ordered(Self.mergeEvents(apple: nowApple ? appleCurrent : [], google: googleSnapshot, interval: currentInterval))
                : self.events
            self.updateChosenCountdowns(currentEvents, now: now)
            self.countdown = NotchCalendarSupport.countdown(currentEvents, now: now, starts: self.countdownEnabled,
                                                            ends: self.timeLeftEnabled, chosen: self.chosenCountdowns,
                                                            leadTime: self.countdownLeadTime)
            self.loading = false
            self.task = nil
            let agendaRefresh = NotchCalendarSupport.nextRefresh(self.events, now: now)
            let countdownRefresh = NotchCalendarSupport.countdownTransition(
                currentEvents, now: now, starts: self.countdownEnabled, ends: self.timeLeftEnabled,
                chosen: self.chosenCountdowns, leadTime: self.countdownLeadTime)
            let nextRefresh = min(agendaRefresh, countdownRefresh ?? agendaRefresh)
            let timer = Timer(fireAt: nextRefresh,
                              interval: 0, target: self, selector: #selector(self.timedRefresh),
                              userInfo: nil, repeats: false)
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.refreshTimer = timer
        }
    }

    private static func mappedGoogleEvents(_ raw: [BaryonCalendarEvent]) -> [NotchCalendarEvent] {
        raw.compactMap { item in
            guard let start = parseGoogleDate(item.start, allDay: item.allDay),
                  let end = parseGoogleDate(item.end, allDay: item.allDay),
                  end > start else { return nil }
            let key = NotchCalendarSupport.countdownKey(identifier: "gcal:\(item.id)", occurrence: start)
            return NotchCalendarEvent(
                id: "gcal:" + item.id + ":" + String(start.timeIntervalSinceReferenceDate),
                title: item.title,
                calendar: item.calendarName.isEmpty ? "Google Calendar" : item.calendarName,
                start: start,
                end: end,
                allDay: item.allDay,
                location: item.location,
                color: parseHexColor(item.color),
                calendarItemIdentifier: "",
                recurring: false,
                countdownKey: key,
                joinURL: item.joinUrl.isEmpty ? nil : item.joinUrl,
                webURL: item.url,
                source: "google"
            )
        }
    }

    private static func mergeEvents(apple: [NotchCalendarEvent], google: [NotchCalendarEvent], interval: DateInterval) -> [NotchCalendarEvent] {
        let filteredGoogle = google.filter { $0.start < interval.end && $0.end > interval.start }
        var result: [NotchCalendarEvent] = []
        var indexByKey: [String: Int] = [:]

        func dedupeKey(_ e: NotchCalendarEvent) -> String {
            let normTitle = e.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let minuteBucket = Int((e.start.timeIntervalSinceReferenceDate / 60.0).rounded())
            return "\(normTitle)|\(minuteBucket)"
        }

        for event in apple {
            let key = dedupeKey(event)
            if indexByKey[key] == nil {
                indexByKey[key] = result.count
                result.append(event)
            }
        }
        for event in filteredGoogle {
            let key = dedupeKey(event)
            if let idx = indexByKey[key] {
                var existing = result[idx]
                if existing.joinURL == nil, let join = event.joinURL { existing.joinURL = join }
                if existing.webURL == nil, let web = event.webURL { existing.webURL = web }
                result[idx] = existing
            } else {
                indexByKey[key] = result.count
                result.append(event)
            }
        }
        return result
    }

    private static func parseGoogleDate(_ value: String, allDay: Bool) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if allDay || trimmed.count == 10 {
            let dayFmt = DateFormatter()
            dayFmt.locale = Locale(identifier: "en_US_POSIX")
            dayFmt.timeZone = Calendar.current.timeZone
            dayFmt.dateFormat = "yyyy-MM-dd"
            if let d = dayFmt.date(from: trimmed) { return d }
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        return isoBasic.date(from: trimmed)
    }

    private static func parseHexColor(_ hex: String) -> NotchCalendarColor {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else {
            return NotchCalendarColor(red: 0.30, green: 0.55, blue: 0.96)
        }
        return NotchCalendarColor(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    @objc private func timedRefresh() { refresh() }

    /// A chosen event read again keeps its current end, and one that has
    /// ended is forgotten. Only the week holding every countdown the island
    /// can show is read; a choice further ahead keeps its end until then.
    private func updateChosenCountdowns(_ events: [NotchCalendarEvent], now: Date) {
        guard !chosenCountdowns.isEmpty,
              let choices = NotchCalendarSupport.refreshedChoices(NotchCalendarSupport.chosenCountdowns(),
                                                                  events: events, now: now) else { return }
        NotchCalendarSupport.storeChosenCountdowns(choices)
        let keys = Set(choices.keys)
        if keys != chosenCountdowns { chosenCountdowns = keys }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        permissionSubscription = nil
        reader = nil
        visibleMonth = nil
        countdownEnabled = false
        timeLeftEnabled = false
        excludedCalendars = []
        if !chosenCountdowns.isEmpty { chosenCountdowns = [] }
        events = []; countdown = nil; loading = false
    }
}
