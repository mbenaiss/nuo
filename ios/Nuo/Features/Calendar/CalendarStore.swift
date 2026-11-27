import Foundation
import Observation
import SwiftUI

/// The merged agenda (events, dated reminders, bookings) and the gateway's calendars, cached in memory and on
/// disk so the agenda shows instantly at launch. The bridge window ([-30 d, +180 d]) is loaded in one request;
/// scrolling past it loads further pages.
@MainActor
@Observable
final class CalendarStore {
    static let shared = CalendarStore()

    private(set) var items: [AgendaItem] = [] {
        didSet { reindex() }
    }
    private(set) var calendars: [CalendarInfo] = []
    /// Events created through Google, shown until the bridge mirrors them back.
    private(set) var pending: [AgendaItem] = [] {
        didSet { reindex() }
    }
    private(set) var loaded = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var range: DateInterval
    /// Bumped on every change, so views that cache layouts know when to redo them.
    private(set) var revision = 0

    var hiddenCalendars: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendars), forKey: Keys.hidden)
            dayCache = [:]
        }
    }
    var showsReminders: Bool {
        didSet {
            UserDefaults.standard.set(showsReminders, forKey: Keys.reminders)
            dayCache = [:]
        }
    }

    @ObservationIgnored private var api: (any NuoAPI)?
    @ObservationIgnored private var byDay: [Date: [AgendaItem]] = [:]
    @ObservationIgnored private var byUid: [String: Int] = [:]
    @ObservationIgnored private var byId: [String: Int] = [:]
    /// Visible items and dot colours per day, and `items` by start: grids, strips and the « À venir » list ask for
    /// them on every render (a month is 42 filter-and-sorts and a hex colour parse per item). Reset on every change.
    @ObservationIgnored private var dayCache: [Date: (items: [AgendaItem], dots: [Color]?)] = [:]
    @ObservationIgnored private var itemsByStart: [AgendaItem]?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    static let pastDays = 30
    static let futureDays = 180
    private static let pageDays = 90

    private enum Keys {
        static let hidden = AppIdentity.local(.calendarHidden)
        static let reminders = AppIdentity.local(.calendarShowsReminders)
        static let itemsCache = "calendar.agenda"
        static let calendarsCache = "calendar.calendars"
    }

    private init() {
        let now = Date()
        range = DateInterval(start: AgendaCalendar.add(-Self.pastDays, to: AgendaCalendar.current.startOfDay(for: now)),
                             end: AgendaCalendar.add(Self.futureDays, to: AgendaCalendar.current.startOfDay(for: now)))
        hiddenCalendars = Set(UserDefaults.standard.stringArray(forKey: Keys.hidden) ?? [])
        showsReminders = UserDefaults.standard.object(forKey: Keys.reminders) as? Bool ?? true
    }

    func attach(_ api: any NuoAPI) {
        self.api = api
    }

    // MARK: Loading

    func load() async {
        guard let api else { return }
        if !loaded {
            async let cachedItems = WorkspaceCache.shared.value([AgendaItem].self, Keys.itemsCache)
            async let cachedCalendars = WorkspaceCache.shared.value([CalendarInfo].self, Keys.calendarsCache)
            if let cached = await cachedItems, !cached.isEmpty {
                items = cached
                loaded = true
            }
            if let cached = await cachedCalendars { calendars = cached }
        }
        isLoading = true
        defer { isLoading = false }
        let window = range
        do {
            async let list = api.calendarList()
            async let page = api.agenda(from: window.start, to: window.end, bookings: true)
            let (fetchedCalendars, fetched) = try await (list, page)
            if calendars != fetchedCalendars { calendars = fetchedCalendars }
            // Pages `ensureLoaded` or `extend` added while this request was out widened `range` past `window`:
            // keep them (but not what the disk cache holds beyond the range).
            let outside = items.filter { item in
                (item.end <= window.start || item.start >= window.end) && item.end > range.start && item.start < range.end
            }
            let merged = Self.merge(fetched + outside)
            // A foreground refresh usually brings back the same agenda: reassigning it would re-render every screen.
            if merged != items { withAnimation(.snappy) { items = merged } }
            loaded = true
            error = nil
            persist()
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }

    /// Coalesces bursts (bridge sync, several writes) into one reload.
    func scheduleRefresh(after delay: Duration = .milliseconds(600)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    /// Loads one more page when the agenda is scrolled near an edge of what is loaded.
    func extend(toward date: Date) async {
        guard let api, !isLoading else { return }
        let page: DateInterval
        if date < range.start.addingTimeInterval(7 * 86400) {
            page = DateInterval(start: AgendaCalendar.add(-Self.pageDays, to: range.start), end: range.start)
        } else if date > range.end.addingTimeInterval(-7 * 86400) {
            page = DateInterval(start: range.end, end: AgendaCalendar.add(Self.pageDays, to: range.end))
        } else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let fetched = try? await api.agenda(from: page.start, to: page.end, bookings: true) else { return }
        absorb(fetched, covering: page)
    }

    /// Loads what a period needs beyond the loaded range: the month grid can jump months away from the edges.
    func ensureLoaded(_ period: DateInterval) async {
        guard let api, loaded else { return }
        var pages: [DateInterval] = []
        if period.start < range.start { pages.append(DateInterval(start: period.start, end: range.start)) }
        if period.end > range.end { pages.append(DateInterval(start: range.end, end: period.end)) }
        for page in pages {
            guard let fetched = try? await api.agenda(from: page.start, to: page.end, bookings: true) else { continue }
            absorb(fetched, covering: page)
        }
    }

    private func absorb(_ fetched: [AgendaItem], covering page: DateInterval) {
        range = DateInterval(start: min(range.start, page.start), end: max(range.end, page.end))
        var known = Dictionary(items.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        for item in fetched { known[item.uid] = item }
        items = Self.merge(Array(known.values))
    }

    private func persist() {
        WorkspaceCache.shared.store(items, Keys.itemsCache)
        WorkspaceCache.shared.store(calendars, Keys.calendarsCache)
    }

    /// Sorts and folds bookings into the Google event the bridge mirrored for them (same title and start), so a
    /// booking shows once, with its badge, whether or not the mirror has arrived yet.
    static func merge(_ raw: [AgendaItem]) -> [AgendaItem] {
        var events = raw.filter { $0.kind != .booking }
        let bookings = raw.filter { $0.kind == .booking }
        var kept: [AgendaItem] = []
        for booking in bookings {
            if let index = events.firstIndex(where: { $0.kind == .event && $0.title == booking.title && abs($0.start.timeIntervalSince(booking.start)) < 60 }) {
                events[index].bookingId = booking.id
            } else {
                kept.append(booking)
            }
        }
        var seen = Set<String>()
        return (events + kept)
            .filter { seen.insert($0.uid).inserted }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.allDay != rhs.allDay { return lhs.allDay }
                return lhs.end < rhs.end
            }
    }

    /// Pending Google events not mirrored yet (same title and start), for at most an hour.
    private var livePending: [AgendaItem] {
        let cutoff = Date().addingTimeInterval(-3600)
        return pending.filter { candidate in
            !items.contains { $0.title == candidate.title && abs($0.start.timeIntervalSince(candidate.start)) < 60 }
                && (pendingAddedAt[candidate.id].map { $0 > cutoff } ?? false)
        }
    }

    @ObservationIgnored private var pendingAddedAt: [String: Date] = [:]

    func addPending(_ item: AgendaItem) {
        pendingAddedAt[item.id] = Date()
        withAnimation(.snappy) { pending.append(item) }
    }

    private func reindex() {
        var index: [Date: [AgendaItem]] = [:]
        for item in items + livePending {
            for day in item.days { index[day, default: []].append(item) }
        }
        byDay = index
        byUid = Dictionary(items.indices.map { (items[$0].uid, $0) }, uniquingKeysWith: { first, _ in first })
        byId = Dictionary(items.indices.map { (items[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        dayCache = [:]
        itemsByStart = nil
        revision += 1
        EventNotifications.scheduleRefresh()
    }

    // MARK: Reading

    func calendar(id: String?) -> CalendarInfo? {
        guard let id else { return nil }
        return calendars.first { $0.id == id }
    }

    private func isVisible(_ item: AgendaItem) -> Bool {
        switch item.kind {
        case .reminder: return showsReminders
        case .event: return !hiddenCalendars.contains(item.calendarId ?? "")
        default: return true
        }
    }

    /// Visible items of a day: all-day first, then by start.
    func items(on day: Date) -> [AgendaItem] {
        // Read like `isVisible` does, so the caller keeps observing the filters.
        _ = (showsReminders, hiddenCalendars)
        let key = AgendaCalendar.current.startOfDay(for: day)
        if let cached = dayCache[key] { return cached.items }
        let items = (byDay[key] ?? []).filter(isVisible).sorted { lhs, rhs in
            if lhs.allDay != rhs.allDay { return lhs.allDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        dayCache[key] = (items, nil)
        return items
    }

    func hasItems(on day: Date) -> Bool {
        (byDay[AgendaCalendar.current.startOfDay(for: day)] ?? []).contains(where: isVisible)
    }

    /// Up to three colors for the dots under a day (day strip, mini month).
    func dotColors(on day: Date) -> [Color] {
        let items = items(on: day)
        let key = AgendaCalendar.current.startOfDay(for: day)
        if let dots = dayCache[key]?.dots { return dots }
        var colors: [Color] = []
        for item in items where item.kind != .reminder || item.done != true {
            let color = item.tint
            if !colors.contains(color) { colors.append(color) }
            if colors.count == 3 { break }
        }
        dayCache[key] = (items, colors)
        return colors
    }

    /// Days of the agenda list: every day holding something, plus today and the day asked for.
    func agendaDays(including extra: [Date]) -> [Date] {
        let calendar = AgendaCalendar.current
        let extras = Set(extra.map { calendar.startOfDay(for: $0) })
        let days = Set(byDay.compactMap { day, items in items.contains(where: isVisible) && range.contains(day) ? day : nil })
        return days.union(extras).sorted()
    }

    /// Timed events still to come (or in progress) and today's open reminders, soonest first.
    func upcoming(limit: Int, from now: Date = Date()) -> [AgendaItem] {
        let items = self.items, pending = livePending
        let sorted: [AgendaItem]
        if pending.isEmpty {
            if itemsByStart == nil { itemsByStart = items.sorted { $0.start < $1.start } }
            sorted = itemsByStart ?? []
        } else {
            sorted = (items + pending).sorted { $0.start < $1.start }
        }
        return Array(sorted.lazy.filter { item in
            guard self.isVisible(item), !item.isCancelled else { return false }
            if item.kind == .reminder { return item.done != true && item.start >= now.addingTimeInterval(-3600) }
            if item.allDay { return false }
            return item.end > now
        }.prefix(limit))
    }

    func item(uid: String) -> AgendaItem? {
        guard let index = byUid[uid] else { return nil }
        return items[index]
    }

    func item(id: String) -> AgendaItem? {
        guard let index = byId[id] else { return nil }
        return items[index]
    }

    /// Calendars Alex may write to from this device (bridge copy present, modifications allowed).
    var writableCalendars: [CalendarInfo] {
        calendars.filter { $0.enabled && $0.allowsModifications && !$0.isBusyOnly }
    }

    // MARK: Changes

    func apply(_ item: AgendaItem) {
        var next = items.filter { $0.uid != item.uid }
        next.append(item)
        withAnimation(.snappy) { items = Self.merge(next) }
        persist()
    }

    func remove(externalIds: Set<String>) {
        withAnimation(.snappy) { items.removeAll { $0.externalId.map(externalIds.contains) ?? false } }
        persist()
    }

    func remove(uid: String) {
        withAnimation(.snappy) { items.removeAll { $0.uid == uid } }
        persist()
    }

    /// Optimistic move while EventKit and the mirror catch up (drag in the week grid).
    func move(uid: String, start: Date, end: Date) {
        guard let index = items.firstIndex(where: { $0.uid == uid }) else { return }
        var item = items[index]
        item.start = start
        item.end = end
        var next = items
        next[index] = item
        items = Self.merge(next)
    }

    func toggleReminder(_ item: AgendaItem) {
        guard let api, item.kind == .reminder else { return }
        let done = !(item.done ?? false)
        done ? Haptics.success() : Haptics.tap()
        var updated = item
        updated.done = done
        apply(updated)
        if done { ReminderNotifications.cancel(item.id) }
        Task {
            if let reminder = try? await api.setReminderDone(id: item.id, done: done) {
                RemindersStore.shared.apply(reminder)
            } else {
                apply(item)
            }
        }
    }

    /// Stores the « Partir maintenant » travel time on the gateway when it changed, for the detail and the widgets.
    /// A travel time the bridge sent (no `travelMode`) wins; `nil` clears one the apps stored.
    func storeTravel(_ item: AgendaItem, seconds: Int?, mode: String?) async {
        guard let api, !item.isBusyOnly, !item.id.hasPrefix("google-") else { return }
        let fromApp = item.travelMode != nil
        if let seconds {
            if item.travelTimeSec != nil, !fromApp { return }
            if fromApp, let known = item.travelTimeSec, abs(known - seconds) < 60, item.travelMode == mode { return }
        } else if !fromApp {
            return
        }
        guard let updated = try? await api.setEventTravel(id: item.id, travelTimeSec: seconds, mode: mode) else { return }
        var merged = item
        merged.travelTimeSec = updated.travelTimeSec
        merged.travelMode = updated.travelMode
        apply(merged)
    }

    func setCalendars(_ list: [CalendarInfo]) {
        calendars = list
        persist()
    }

    @discardableResult
    func patchCalendar(_ id: String, _ patch: [String: JSONValue]) async -> Bool {
        guard let api else { return false }
        do {
            let updated = try await api.patchCalendar(id: id, patch: patch)
            if let index = calendars.firstIndex(where: { $0.id == id }) { calendars[index] = updated }
            persist()
            scheduleRefresh(after: .milliseconds(200))
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func toggleVisibility(_ calendarId: String) {
        if hiddenCalendars.contains(calendarId) { hiddenCalendars.remove(calendarId) } else { hiddenCalendars.insert(calendarId) }
        revision += 1
    }
}
