import CoreLocation
import CryptoKit
import EventKit
import Foundation
import Observation
import SwiftUI
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// What the editor and the quick entry hand to the bridge.
struct EventDraft: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var location: String?
    var coordinates: GeoPoint?
    var notes: String?
    var url: String?
    /// Gateway calendar id (`CalendarInfo.id`).
    var calendarId: String?
    var alarmMinutes: Int?
    var recurrence: EventRecurrence?
    var free = false
    /// Invitations go through Google (`POST /api/calendar/events`): EventKit cannot add attendees.
    var attendees: [String] = []
    var meet = false

    init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil, coordinates: GeoPoint? = nil, notes: String? = nil,
         url: String? = nil, calendarId: String? = nil, alarmMinutes: Int? = nil, recurrence: EventRecurrence? = nil, free: Bool = false,
         attendees: [String] = [], meet: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.coordinates = coordinates
        self.notes = notes
        self.url = url
        self.calendarId = calendarId
        self.alarmMinutes = alarmMinutes
        self.recurrence = recurrence
        self.free = free
        self.attendees = attendees
        self.meet = meet
    }

    init(_ parsed: ParsedEvent, calendarId: String?) {
        self.init(title: parsed.title, start: parsed.start, end: parsed.end, allDay: parsed.allDay, location: parsed.location,
                  calendarId: parsed.calendarId ?? calendarId, alarmMinutes: parsed.alarmMinutes, recurrence: parsed.recurrence,
                  attendees: parsed.attendees, meet: parsed.meet)
    }

    init(_ item: AgendaItem) {
        self.init(title: item.title ?? "", start: item.start, end: item.end, allDay: item.allDay, location: item.location,
                  coordinates: item.coordinates, notes: item.notes, url: item.url, calendarId: item.calendarId,
                  alarmMinutes: Self.alarmMinutes(item), free: item.isFree)
    }

    /// The editor holds one alert: the first one before the start, else 15 min for events known only to have one.
    private static func alarmMinutes(_ item: AgendaItem) -> Int? {
        if let offset = item.alarms?.compactMap(\.offsetSec).filter({ $0 <= 0 }).max() { return -offset / 60 }
        return item.hasAlarms == true ? 15 : nil
    }

    var needsGoogle: Bool { !attendees.isEmpty || meet }
}

enum CalendarBridgeError: LocalizedError {
    case noAccess, calendarNotOnDevice, eventNotFound, readOnly

    var errorDescription: String? {
        switch self {
        case .noAccess: String(localized: "Nuo can't access your calendars. Allow it in Settings › Privacy › Calendars.")
        case .calendarNotOnDevice: String(localized: "This calendar is not on this device: edit it from the device that syncs it.")
        case .eventNotFound: String(localized: "Event not found in this device's calendars.")
        case .readOnly: String(localized: "This calendar is read only.")
        }
    }
}

/// Bridges this device's EventKit calendars to the gateway (docs/calendar.md): sources, full and incremental syncs,
/// and local writes mirrored at once. The Mac is the primary bridge, the iPhone a fallback; the gateway dedupes.
@MainActor
@Observable
final class CalendarBridge {
    static let shared = CalendarBridge()

    enum Access: Equatable { case notDetermined, denied, writeOnly, full }

    private(set) var access: Access = .notDetermined
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isDemo = false

    @ObservationIgnored private(set) var api: (any NuoAPI)?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private let reader = EventKitReader()
    @ObservationIgnored private var state = BridgeState.load()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var syncedThisLaunch = false
    /// Whether an EventKit calendar exists on this device, asked for every event of the grids on each render.
    @ObservationIgnored private var onDevice: [String: Bool] = [:]
    @ObservationIgnored private var pendingRun = false

    /// While the app runs, a light incremental pass catches changes EventKit did not announce.
    static let periodicInterval: Duration = .seconds(15 * 60)
    /// A complete pass (the gateway removes what it no longer hears about) at least this often.
    static let fullInterval: TimeInterval = 6 * 3600
    static let batchLimit = 500
    private static let changeDebounce: Duration = .seconds(3)

    private init() {
        refreshAccess()
    }

    func attach(_ api: any NuoAPI, demo: Bool) {
        self.api = api
        isDemo = demo
        if demo { access = .full }
    }

    // MARK: Access

    func refreshAccess() {
        guard !isDemo else { return }
        onDevice = [:]
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .full
        case .writeOnly: access = .writeOnly
        case .denied, .restricted: access = .denied
        case .notDetermined: access = .notDetermined
        @unknown default: access = .denied
        }
    }

    @discardableResult
    func requestAccess() async -> Bool {
        guard !isDemo else { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        refreshAccess()
        if granted { start() }
        return granted
    }

    // MARK: Lifecycle

    /// Starts observing EventKit and syncing; a no-op until full access is granted.
    func start() {
        refreshAccess()
        guard !isDemo, access == .full, api != nil, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.eventStoreChanged() }
        }
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicInterval)
                await self?.sync()
            }
        }
        Task { await sync() }
    }

    func appBecameActive() {
        refreshAccess()
        if observer == nil { start(); return }
        guard let lastSync, Date().timeIntervalSince(lastSync) > 60 else { return }
        Task { await sync() }
    }

    private func eventStoreChanged() {
        onDevice = [:]
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: Sync

    /// Pushes sources, then each enabled calendar: everything when `full` (or on the first pass of a launch, or
    /// every few hours), only what changed since the last pass otherwise.
    func sync(full requested: Bool = false) async {
        guard !isDemo, access == .full, let api else { return }
        if isSyncing { pendingRun = true; return }
        isSyncing = true
        defer {
            isSyncing = false
            if pendingRun {
                pendingRun = false
                Task { await sync() }
            }
        }
        let full = requested || !syncedThisLaunch || Date().timeIntervalSince(state.lastFull ?? .distantPast) > Self.fullInterval
        let window = Self.window()
        do {
            let sources = await reader.sources()
            let infos = try await api.putCalendarSources(sources)
            CalendarStore.shared.setCalendars(infos)
            var next = state
            next.fingerprints = next.fingerprints.filter { id, _ in sources.contains { $0.id == id } }
            var batches: [SyncCalendarBatch] = []
            for source in sources {
                guard let info = infos.first(where: { $0.sources.contains { $0.calendarIdentifier == source.id } }), info.enabled else {
                    next.fingerprints[source.id] = nil
                    continue
                }
                let events = await reader.events(calendarId: source.id, window: window, busyOnly: info.isBusyOnly)
                let digests = Dictionary(events.map { ($0.externalId, Self.digest($0)) }, uniquingKeysWith: { first, _ in first })
                let previous = state.fingerprints[source.id]
                if full || info.needsResync == true || previous == nil {
                    batches += Self.chunks(calendarId: source.id, window: window, events: events, deleted: [], complete: true)
                } else if let previous {
                    let changed = events.filter { previous[$0.externalId] != digests[$0.externalId] }
                    let deleted = previous.keys.filter { digests[$0] == nil }
                    if !changed.isEmpty || !deleted.isEmpty {
                        batches += Self.chunks(calendarId: source.id, window: window, events: changed, deleted: Array(deleted), complete: false)
                    }
                }
                next.fingerprints[source.id] = digests
            }
            let syncId = UUID().uuidString
            for request in Self.requests(batches, syncId: syncId) {
                _ = try await api.syncCalendar(request)
            }
            if full { next.lastFull = Date() }
            state = next
            state.save()
            syncedThisLaunch = true
            lastSync = Date()
            lastError = nil
            if !batches.isEmpty { CalendarStore.shared.scheduleRefresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func window(now: Date = Date()) -> SyncWindow {
        let calendar = AgendaCalendar.current
        let today = calendar.startOfDay(for: now)
        return SyncWindow(from: AgendaCalendar.add(-CalendarStore.pastDays, to: today), to: AgendaCalendar.add(CalendarStore.futureDays, to: today))
    }

    /// One calendar's events cut into batches; only the last one carries `complete`.
    private static func chunks(calendarId: String, window: SyncWindow, events: [BridgeEvent], deleted: [String], complete: Bool) -> [SyncCalendarBatch] {
        guard !events.isEmpty else {
            return [SyncCalendarBatch(calendarId: calendarId, window: window, events: [], deleted: deleted, complete: complete)]
        }
        var result: [SyncCalendarBatch] = []
        var start = 0
        while start < events.count {
            let end = min(start + batchLimit, events.count)
            let last = end == events.count
            result.append(SyncCalendarBatch(calendarId: calendarId, window: window, events: Array(events[start..<end]),
                                            deleted: last ? deleted : [], complete: last && complete))
            start = end
        }
        return result
    }

    /// Packs batches of several calendars into requests of at most `batchLimit` events (the body limit is 4 MB).
    private static func requests(_ batches: [SyncCalendarBatch], syncId: String) -> [SyncRequest] {
        var requests: [SyncRequest] = []
        var current: [SyncCalendarBatch] = []
        var count = 0
        for batch in batches {
            if count + batch.events.count > batchLimit, !current.isEmpty {
                requests.append(SyncRequest(syncId: syncId, calendars: current))
                current = []
                count = 0
            }
            current.append(batch)
            count += batch.events.count
        }
        if !current.isEmpty { requests.append(SyncRequest(syncId: syncId, calendars: current)) }
        return requests
    }

    private static func digest(_ event: BridgeEvent) -> String {
        let encoder = NuoJSON.encoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(event)) ?? Data(event.externalId.utf8)
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Writes

    /// The EventKit calendar of this device behind a gateway calendar.
    private func ekCalendar(for calendarId: String?) -> EKCalendar? {
        guard let info = CalendarStore.shared.calendar(id: calendarId) else { return store.defaultCalendarForNewEvents }
        return info.sources.lazy.compactMap { self.store.calendar(withIdentifier: $0.calendarIdentifier) }.first
    }

    /// The device calendar identifier a demo write goes to (no EventKit in the demo).
    private func demoIdentifier(_ calendarId: String?) -> String? {
        CalendarStore.shared.calendar(id: calendarId)?.sources.first?.calendarIdentifier
            ?? CalendarStore.shared.writableCalendars.first?.sources.first?.calendarIdentifier
    }

    /// Default calendar for new events: the one picked in the settings, else EventKit's default.
    var defaultCalendarId: String? {
        let saved = UserDefaults.standard.string(forKey: AppIdentity.local(.calendarDefault))
        let writable = CalendarStore.shared.writableCalendars
        if let saved, writable.contains(where: { $0.id == saved }) { return saved }
        if !isDemo, let identifier = store.defaultCalendarForNewEvents?.calendarIdentifier,
           let info = writable.first(where: { $0.sources.contains { $0.calendarIdentifier == identifier } }) {
            return info.id
        }
        return writable.first?.id
    }

    func setDefaultCalendar(_ id: String) {
        UserDefaults.standard.set(id, forKey: AppIdentity.local(.calendarDefault))
    }

    /// Creates the event (EventKit, or Google when it invites people) and mirrors it to the gateway at once.
    @discardableResult
    func create(_ draft: EventDraft) async throws -> AgendaItem? {
        guard let api else { return nil }
        if draft.needsGoogle { return try await createInGoogle(draft) }
        if isDemo { return try await demoWrite(draft, externalId: "local-\(UUID().uuidString.prefix(8))") }
        guard access == .full || access == .writeOnly else { throw CalendarBridgeError.noAccess }
        guard let calendar = ekCalendar(for: draft.calendarId) else { throw CalendarBridgeError.calendarNotOnDevice }
        guard calendar.allowsContentModifications else { throw CalendarBridgeError.readOnly }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        fill(event, with: draft)
        try store.save(event, span: .thisEvent, commit: true)
        Haptics.success()
        if draft.recurrence != nil {
            await sync()
            return nil
        }
        let mirrored = try? await api.syncEvent(calendarId: calendar.calendarIdentifier, event: EventKitMapper.bridgeEvent(event, busyOnly: false))
        if let mirrored { CalendarStore.shared.apply(mirrored) }
        return mirrored
    }

    private func createInGoogle(_ draft: EventDraft) async throws -> AgendaItem? {
        guard let api else { return nil }
        let day = DateFormatter()
        day.calendar = AgendaCalendar.current
        day.dateFormat = "yyyy-MM-dd"
        let body = GoogleEventDraft(
            title: draft.title,
            start: draft.allDay ? day.string(from: draft.start) : NuoJSON.formatDate(draft.start),
            end: draft.allDay ? day.string(from: draft.end) : NuoJSON.formatDate(draft.end),
            allDay: draft.allDay, location: draft.location, notes: draft.notes,
            attendees: draft.attendees.isEmpty ? nil : draft.attendees, meet: draft.meet, target: nil)
        let result = try await api.createGoogleEvent(body)
        Haptics.success()
        let pending = AgendaItem(kind: .event, id: "google-\(result.googleEventId)", title: draft.title, location: draft.location,
                                 conferenceUrl: result.meetUrl, start: draft.start, end: draft.end, allDay: draft.allDay,
                                 availability: "busy", status: "confirmed",
                                 attendees: draft.attendees.map { CalendarAttendee(name: EventParser.displayName($0), email: $0, status: "pending") },
                                 color: "#4285F4")
        CalendarStore.shared.addPending(pending)
        CalendarStore.shared.scheduleRefresh(after: .seconds(isDemo ? 0 : 20))
        return pending
    }

    /// Saves the changes; for a recurring event `futureEvents` applies them to this and the following occurrences.
    func update(_ item: AgendaItem, with draft: EventDraft, span: EKSpan = .thisEvent) async throws {
        guard let api else { return }
        if isDemo {
            _ = try await demoWrite(draft, externalId: item.externalId ?? "local-\(item.id)", previous: item)
            return
        }
        let event = try ekEvent(for: item)
        let oldCalendar = event.calendar
        if let target = ekCalendar(for: draft.calendarId), target.calendarIdentifier != event.calendar.calendarIdentifier {
            guard target.allowsContentModifications else { throw CalendarBridgeError.readOnly }
            event.calendar = target
        }
        fill(event, with: draft)
        try store.save(event, span: span, commit: true)
        Haptics.success()
        let moved = oldCalendar?.calendarIdentifier != event.calendar.calendarIdentifier
        if span == .futureEvents || moved || item.isRecurring || draft.recurrence != nil {
            CalendarStore.shared.apply(Self.preview(item, draft))
            await sync()
            return
        }
        if let mirrored = try? await api.syncEvent(calendarId: event.calendar.calendarIdentifier, event: EventKitMapper.bridgeEvent(event, busyOnly: false)) {
            if mirrored.uid != item.uid { CalendarStore.shared.remove(uid: item.uid) }
            CalendarStore.shared.apply(mirrored)
        }
    }

    /// Drag in a time grid: new times only.
    func move(_ item: AgendaItem, start: Date, end: Date) async throws {
        CalendarStore.shared.move(uid: item.uid, start: start, end: end)
        var draft = EventDraft(item)
        draft.start = start
        draft.end = end
        draft.alarmMinutes = nil
        let event: EKEvent
        do {
            if isDemo {
                _ = try await demoWrite(draft, externalId: item.externalId ?? item.id, previous: item)
                return
            }
            event = try ekEvent(for: item)
            event.startDate = start
            event.endDate = end
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            CalendarStore.shared.apply(item)
            throw error
        }
        if let api, let mirrored = try? await api.syncEvent(calendarId: event.calendar.calendarIdentifier, event: EventKitMapper.bridgeEvent(event, busyOnly: false)) {
            CalendarStore.shared.apply(mirrored)
        }
    }

    func delete(_ item: AgendaItem, span: EKSpan = .thisEvent) async throws {
        guard let api else { return }
        if isDemo {
            CalendarStore.shared.remove(uid: item.uid)
            if let external = item.externalId, let identifier = demoIdentifier(item.calendarId) {
                let ids = span == .futureEvents && item.seriesId != nil
                    ? CalendarStore.shared.items.filter { $0.seriesId == item.seriesId && $0.start >= item.start }.compactMap(\.externalId)
                    : [external]
                try await api.deleteSyncedEvents(calendarId: identifier, externalIds: ids)
                CalendarStore.shared.remove(externalIds: Set(ids))
            }
            return
        }
        let event = try ekEvent(for: item)
        let identifier = event.calendar.calendarIdentifier
        try store.remove(event, span: span, commit: true)
        // Only once EventKit agreed: a refused delete must leave the event on screen.
        CalendarStore.shared.remove(uid: item.uid)
        Haptics.success()
        if span == .futureEvents {
            await sync()
        } else if let external = item.externalId {
            try? await api.deleteSyncedEvents(calendarId: identifier, externalIds: [external])
        }
    }

    /// Demo writes skip EventKit and land in the demo gateway, as the mirror would.
    private func demoWrite(_ draft: EventDraft, externalId: String, previous: AgendaItem? = nil) async throws -> AgendaItem? {
        guard let api, let identifier = demoIdentifier(draft.calendarId) else { return nil }
        if let previous, let oldIdentifier = demoIdentifier(previous.calendarId), oldIdentifier != identifier, let external = previous.externalId {
            try await api.deleteSyncedEvents(calendarId: oldIdentifier, externalIds: [external])
            CalendarStore.shared.remove(uid: previous.uid)
        }
        let event = BridgeEvent(externalId: externalId, seriesId: previous?.seriesId, title: draft.title, location: draft.location,
                                coordinates: draft.coordinates, notes: draft.notes, url: draft.url, start: draft.start, end: draft.end,
                                allDay: draft.allDay, availability: draft.free ? "free" : "busy", status: "confirmed",
                                attendees: previous?.attendees, organizer: previous?.organizer, hasAlarms: draft.alarmMinutes != nil,
                                alarms: draft.alarmMinutes.map { [EventAlarm(offsetSec: -$0 * 60)] })
        let item = try await api.syncEvent(calendarId: identifier, event: event)
        if let item { CalendarStore.shared.apply(item) }
        Haptics.success()
        return item
    }

    private static func preview(_ item: AgendaItem, _ draft: EventDraft) -> AgendaItem {
        var copy = item
        copy.title = draft.title
        copy.start = draft.start
        copy.end = draft.end
        copy.allDay = draft.allDay
        copy.location = draft.location
        copy.notes = draft.notes
        copy.url = draft.url
        return copy
    }

    /// The EventKit occurrence behind an agenda item: same series id and, for recurring events, same occurrence.
    func ekEvent(for item: AgendaItem) throws -> EKEvent {
        guard access == .full else { throw CalendarBridgeError.noAccess }
        guard let info = CalendarStore.shared.calendar(id: item.calendarId) else { throw CalendarBridgeError.eventNotFound }
        let calendars = info.sources.compactMap { store.calendar(withIdentifier: $0.calendarIdentifier) }
        guard !calendars.isEmpty else { throw CalendarBridgeError.calendarNotOnDevice }
        let (base, occurrence) = EventKitMapper.split(item.externalId ?? "")
        let predicate = store.predicateForEvents(withStart: item.start.addingTimeInterval(-86400), end: item.end.addingTimeInterval(86400), calendars: calendars)
        let candidates = store.events(matching: predicate).filter { ($0.calendarItemExternalIdentifier ?? $0.eventIdentifier) == base }
        if let occurrence, let match = candidates.first(where: { abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(occurrence)) < 1 }) {
            return match
        }
        guard let match = candidates.min(by: { abs($0.startDate.timeIntervalSince(item.start)) < abs($1.startDate.timeIntervalSince(item.start)) }) else {
            throw CalendarBridgeError.eventNotFound
        }
        return match
    }

    /// Whether this device can write the item through EventKit (or the demo).
    func canEdit(_ item: AgendaItem) -> Bool {
        guard item.kind == .event, !item.isBusyOnly, item.editable != false, !item.id.hasPrefix("google-") else { return false }
        if isDemo { return true }
        guard access == .full, let info = CalendarStore.shared.calendar(id: item.calendarId) else { return false }
        return info.sources.contains { isOnDevice($0.calendarIdentifier) }
    }

    private func isOnDevice(_ calendarIdentifier: String) -> Bool {
        if let known = onDevice[calendarIdentifier] { return known }
        let found = store.calendar(withIdentifier: calendarIdentifier) != nil
        onDevice[calendarIdentifier] = found
        return found
    }

    private func fill(_ event: EKEvent, with draft: EventDraft) {
        event.title = draft.title
        event.isAllDay = draft.allDay
        event.startDate = draft.start
        event.endDate = draft.allDay ? draft.end.addingTimeInterval(-1) : draft.end
        if let location = draft.location, !location.isEmpty {
            if let point = draft.coordinates {
                let structured = EKStructuredLocation(title: location)
                structured.geoLocation = CLLocation(latitude: point.lat, longitude: point.lon)
                event.structuredLocation = structured
            } else {
                event.location = location
            }
        } else {
            event.location = nil
        }
        event.notes = draft.notes?.isEmpty == false ? draft.notes : nil
        event.url = draft.url.flatMap(URL.init(string:))
        event.availability = draft.free ? .free : .busy
        event.alarms = draft.alarmMinutes.map { [EKAlarm(relativeOffset: -Double($0) * 60)] }
        if let recurrence = draft.recurrence {
            event.recurrenceRules = [EventKitMapper.rule(recurrence)]
        }
    }

    // MARK: Background refresh (iPhone)

    #if os(iOS)
    nonisolated static let backgroundTaskId = AppIdentity.scoped("calendar-sync")

    /// Must run before the app finishes launching.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            let box = BackgroundTaskBox(task: refresh)
            let work = Task { @MainActor in
                CalendarBridge.shared.scheduleBackgroundRefresh()
                if CalendarBridge.shared.api == nil, let api = ReminderNotifications.api() {
                    CalendarBridge.shared.attach(api, demo: false)
                    CalendarStore.shared.attach(api)
                    PlacesStore.shared.attach(api)
                }
                await CalendarBridge.shared.sync()
                async let places: Void = PlacesStore.shared.load()
                await CalendarStore.shared.load()
                await places
                await EventNotifications.refresh()
                CalendarBridge.shared.scheduleBackgroundRefresh()
                box.task.setTaskCompleted(success: CalendarBridge.shared.lastError == nil)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    /// Hourly, or earlier to recompute a « Partir maintenant » ETA shortly before the departure (best effort: iOS decides).
    func scheduleBackgroundRefresh() {
        guard !isDemo else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskId)
        let hour = Date().addingTimeInterval(3600)
        let departure = EventNotifications.nextTravelCheck.map { max($0, Date().addingTimeInterval(15 * 60)) }
        request.earliestBeginDate = min(hour, departure ?? hour)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}

#if os(iOS)
/// BGTask is not Sendable; it is only completed once, from the main actor.
private final class BackgroundTaskBox: @unchecked Sendable {
    let task: BGAppRefreshTask
    init(task: BGAppRefreshTask) { self.task = task }
}
#endif

/// Reads EventKit off the main actor with its own store: a full pass expands months of occurrences.
actor EventKitReader {
    private let store = EKEventStore()

    func sources() -> [BridgeCalendar] {
        store.calendars(for: .event).map { calendar in
            BridgeCalendar(id: calendar.calendarIdentifier, title: calendar.title, color: EventKitMapper.hex(calendar.cgColor),
                           account: calendar.source?.title, type: EventKitMapper.type(calendar.type), allowsModifications: calendar.allowsContentModifications)
        }
    }

    func events(calendarId: String, window: SyncWindow, busyOnly: Bool) -> [BridgeEvent] {
        guard let calendar = store.calendar(withIdentifier: calendarId) else { return [] }
        var result: [BridgeEvent] = []
        var seen = Set<String>()
        // EventKit caps a predicate at four years; the window is far shorter, but months keep each fetch light.
        var start = window.from
        while start < window.to {
            let end = min(AgendaCalendar.current.date(byAdding: .month, value: 1, to: start) ?? window.to, window.to)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            for event in store.events(matching: predicate) {
                let mapped = EventKitMapper.bridgeEvent(event, busyOnly: busyOnly)
                if seen.insert(mapped.externalId).inserted { result.append(mapped) }
            }
            start = end
        }
        return result
    }
}

enum EventKitMapper {
    static func bridgeEvent(_ event: EKEvent, busyOnly: Bool) -> BridgeEvent {
        let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        let recurring = event.hasRecurrenceRules || event.isDetached
        let occurrence = event.occurrenceDate ?? event.startDate ?? Date()
        let externalId = recurring ? "\(base)@\(NuoJSON.formatDate(occurrence))" : base
        var start = event.startDate ?? Date()
        var end = event.endDate ?? start
        if event.isAllDay {
            let calendar = AgendaCalendar.current
            start = calendar.startOfDay(for: start)
            let lastDay = calendar.startOfDay(for: end)
            end = lastDay == end && end > start ? end : (calendar.date(byAdding: .day, value: 1, to: lastDay) ?? end)
        }
        let full = BridgeEvent(
            externalId: externalId, seriesId: recurring ? base : nil, title: event.title,
            location: event.structuredLocation?.title?.nilIfEmpty ?? event.location?.nilIfEmpty,
            coordinates: event.structuredLocation?.geoLocation.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) },
            notes: event.notes?.nilIfEmpty, url: event.url?.absoluteString, start: start, end: end, allDay: event.isAllDay,
            availability: availability(event.availability), status: status(event.status),
            attendees: event.attendees.map { participants in participants.map { attendee($0, organizer: event.organizer) } },
            attendeesCount: event.attendees?.count,
            organizer: event.organizer.map { CalendarPerson(name: $0.name, email: email($0)) },
            travelTimeSec: nil, hasAlarms: event.hasAlarms, alarms: alarms(event))
        return busyOnly ? full.busyOnly : full
    }

    /// Time alarms only: proximity alarms fire on arrival or departure, which the apps never schedule.
    static func alarms(_ event: EKEvent) -> [EventAlarm]? {
        guard let alarms = event.alarms else { return nil }
        return alarms.filter { $0.proximity == .none }.map { alarm in
            if let date = alarm.absoluteDate { return EventAlarm(at: date) }
            return EventAlarm(offsetSec: Int(alarm.relativeOffset.rounded()))
        }
    }

    /// `"<uid>@<ISO occurrence>"` → uid and occurrence; uids may contain `@` themselves (`…@google.com`).
    static func split(_ externalId: String) -> (base: String, occurrence: Date?) {
        guard let at = externalId.lastIndex(of: "@") else { return (externalId, nil) }
        let suffix = String(externalId[externalId.index(after: at)...])
        guard let date = NuoJSON.parseDate(suffix) else { return (externalId, nil) }
        return (String(externalId[..<at]), date)
    }

    static func availability(_ value: EKEventAvailability) -> String {
        switch value {
        case .free: "free"
        case .tentative: "tentative"
        case .unavailable: "unavailable"
        default: "busy"
        }
    }

    static func status(_ value: EKEventStatus) -> String? {
        switch value {
        case .confirmed: "confirmed"
        case .tentative: "tentative"
        case .canceled: "cancelled"
        default: nil
        }
    }

    static func email(_ participant: EKParticipant) -> String? {
        let text = participant.url.absoluteString
        guard text.lowercased().hasPrefix("mailto:") else { return nil }
        return String(text.dropFirst("mailto:".count)).removingPercentEncoding
    }

    static func attendee(_ participant: EKParticipant, organizer: EKParticipant?) -> CalendarAttendee {
        let status: String = switch participant.participantStatus {
        case .accepted, .completed: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending, .inProcess: "pending"
        default: "unknown"
        }
        let isOrganizer = organizer.map { $0.url == participant.url } ?? false
        return CalendarAttendee(name: participant.name, email: email(participant), status: status, organizer: isOrganizer ? true : nil)
    }

    static func type(_ type: EKCalendarType) -> String {
        switch type {
        case .local: "local"
        case .calDAV: "caldav"
        case .exchange: "exchange"
        case .subscription: "subscription"
        case .birthday: "birthday"
        @unknown default: "local"
        }
    }

    static func hex(_ color: CGColor?) -> String? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        let value = components.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value[0], value[1], value[2])
    }

    static func rule(_ recurrence: EventRecurrence) -> EKRecurrenceRule {
        func day(_ index: Int) -> EKRecurrenceDayOfWeek { EKRecurrenceDayOfWeek(EKWeekday(rawValue: index + 1) ?? .monday) }
        switch recurrence {
        case .daily: return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: (1...5).map(day), daysOfTheMonth: nil,
                                    monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        case let .weekly(days):
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days.isEmpty ? nil : days.map(day), daysOfTheMonth: nil,
                                    monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        case .monthly: return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }
}

/// Fingerprints of what each calendar last sent, so an incremental pass only pushes changes and deletions.
private struct BridgeState: Codable {
    var fingerprints: [String: [String: String]] = [:]
    var lastFull: Date?

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("calendar-bridge.json")
    }

    static func load() -> BridgeState {
        guard let data = try? Data(contentsOf: url), let state = try? NuoJSON.decoder().decode(BridgeState.self, from: data) else { return BridgeState() }
        return state
    }

    func save() {
        let url = Self.url
        guard let data = try? NuoJSON.encoder().encode(self) else { return }
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}
