import Foundation
import MapKit
import Observation

enum TravelMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case driving, transit, walking, cycling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .driving: String(localized: "Car")
        case .transit: String(localized: "Transit")
        case .walking: String(localized: "Walking")
        case .cycling: String(localized: "Cycling")
        }
    }

    /// "25 min by car".
    var phrase: String {
        switch self {
        case .driving: String(localized: "by car")
        case .transit: String(localized: "by transit")
        case .walking: String(localized: "on foot")
        case .cycling: String(localized: "by bike")
        }
    }

    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .transit: "tram.fill"
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .transit: .transit
        case .walking: .walking
        case .cycling: .cycling
        }
    }

    var mapsMode: String {
        switch self {
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .cycling: MKLaunchOptionsDirectionsModeCycling
        }
    }
}

/// “Leave now” for one event: off, or from another saved place.
struct LeaveOverride: Codable, Hashable, Sendable {
    var disabled = false
    var originPlaceId: String?
}

/// Settings of event alerts and “Leave now”, per device. The origin is always a place the user saved:
/// travel times are never computed from the device's position.
@MainActor
@Observable
final class EventAlertSettings {
    static let shared = EventAlertSettings()

    static let defaultAlertChoices = [5, 10, 15, 30]
    static let marginChoices = [0, 5, 10, 15, 20, 30]
    /// Widgets read the margin to show “Leave for”.
    static let appGroup = AppIdentity.appGroup
    static let marginKey = "nuo.leave.marginMin"

    var eventsEnabled: Bool { didSet { save() } }
    var leaveEnabled: Bool { didSet { save() } }
    /// Alert for events that have none; `nil` = none.
    var defaultAlertMinutes: Int? { didSet { save() } }
    /// `nil` = the place named “Home” (or “Maison”).
    var originPlaceId: String? { didSet { save() } }
    var mode: TravelMode { didSet { save() } }
    var marginMinutes: Int { didSet { save() } }
    private(set) var overrides: [String: LeaveOverride]

    private enum Keys {
        static let events = "nuo.eventAlerts.events"
        static let leave = "nuo.eventAlerts.leave"
        static let defaultAlert = "nuo.eventAlerts.defaultAlert"
        static let origin = "nuo.eventAlerts.origin"
        static let mode = "nuo.eventAlerts.mode"
        static let margin = "nuo.eventAlerts.margin"
        static let overrides = "nuo.eventAlerts.overrides"
    }

    private init() {
        let defaults = UserDefaults.standard
        eventsEnabled = defaults.object(forKey: Keys.events) as? Bool ?? true
        leaveEnabled = defaults.object(forKey: Keys.leave) as? Bool ?? true
        let alert = defaults.object(forKey: Keys.defaultAlert) as? Int ?? -1
        defaultAlertMinutes = alert >= 0 ? alert : nil
        originPlaceId = defaults.string(forKey: Keys.origin)
        mode = defaults.string(forKey: Keys.mode).flatMap(TravelMode.init(rawValue:)) ?? .driving
        marginMinutes = defaults.object(forKey: Keys.margin) as? Int ?? 5
        overrides = defaults.data(forKey: Keys.overrides).flatMap { try? JSONDecoder().decode([String: LeaveOverride].self, from: $0) } ?? [:]
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(eventsEnabled, forKey: Keys.events)
        defaults.set(leaveEnabled, forKey: Keys.leave)
        defaults.set(defaultAlertMinutes ?? -1, forKey: Keys.defaultAlert)
        defaults.set(originPlaceId, forKey: Keys.origin)
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(marginMinutes, forKey: Keys.margin)
        UserDefaults(suiteName: Self.appGroup)?.set(marginMinutes, forKey: Self.marginKey)
        EventNotifications.scheduleRefresh()
    }

    var margin: TimeInterval { TimeInterval(marginMinutes * 60) }

    // MARK: Origin

    /// The place chosen in the settings, else “Home”.
    func defaultOrigin(in places: [Place]) -> Place? {
        if let originPlaceId, let place = places.first(where: { $0.id == originPlaceId }) { return place }
        return places.first { ["maison", "home"].contains($0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }

    func origin(for item: AgendaItem, in places: [Place]) -> Place? {
        if let id = override(for: item)?.originPlaceId, let place = places.first(where: { $0.id == id }) { return place }
        return defaultOrigin(in: places)
    }

    // MARK: Per event

    /// Calendar and external id, which stay the same whichever device's copy the gateway serves.
    static func overrideKey(_ item: AgendaItem) -> String { "\(item.calendarId ?? "")|\(item.externalId ?? item.id)" }

    func override(for item: AgendaItem) -> LeaveOverride? { overrides[Self.overrideKey(item)] }

    func setOverride(_ value: LeaveOverride?, for item: AgendaItem) {
        let key = Self.overrideKey(item)
        overrides[key] = value == LeaveOverride() ? nil : value
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Keys.overrides) }
        EventNotifications.scheduleRefresh(after: .milliseconds(300))
    }
}

/// iOS keeps 64 pending notification requests per app. Reminders and events share them soonest first, each kind
/// keeping a minimum when it needs it; location triggers of reminders and a few snoozes come off the top.
@MainActor
enum NotificationBudget {
    static let capacity = 58
    static let minimum = 12

    /// Shares each side last applied (never above its candidate count), so one side asks the other to resync when
    /// the other's share moved.
    private static var reminderShare: Int?
    private static var eventShare: Int?

    nonisolated static func split(reminders: [Date], events: [Date], capacity: Int, minimum: Int) -> (reminders: Int, events: Int) {
        let r = reminders.sorted(), e = events.sorted()
        var i = 0, j = 0
        while i + j < capacity, i < r.count || j < e.count {
            if j >= e.count || (i < r.count && r[i] <= e[j]) { i += 1 } else { j += 1 }
        }
        let rMin = min(minimum, r.count), eMin = min(minimum, e.count)
        if i < rMin { j = max(eMin, min(j, capacity - rMin)); i = min(r.count, capacity - j) }
        if j < eMin { i = max(rMin, min(i, capacity - eMin)); j = min(e.count, capacity - i) }
        return (i, j)
    }

    static func quotas(reminders: [Reminder], now: Date) -> (reminders: Int, events: Int) {
        split(reminders: ReminderNotifications.candidateDates(reminders, now: now),
              events: EventNotifications.candidateDates(now: now),
              capacity: capacity - locationSlots(reminders), minimum: minimum)
    }

    private static func locationSlots(_ reminders: [Reminder]) -> Int {
        #if os(iOS)
        min(reminders.filter { !$0.isDone && $0.place != nil }.count, LocationTriggers.limit)
        #else
        0
        #endif
    }

    static func didScheduleReminders(_ shares: (reminders: Int, events: Int)) {
        reminderShare = shares.reminders
        if let eventShare, eventShare != shares.events { EventNotifications.scheduleRefresh() }
    }

    static func didScheduleEvents(_ shares: (reminders: Int, events: Int)) {
        eventShare = shares.events
        if let reminderShare, reminderShare != shares.reminders { RemindersStore.shared.refreshTriggers() }
    }
}
