import CoreLocation
import Foundation
import MapKit
import UserNotifications

/// Local notifications of events: alerts (the event's alarms, or the default alert) and « Partir maintenant ».
/// Scheduled from the merged agenda, so calendars only the Mac bridges notify here too; refreshed on agenda
/// changes, on foreground, hourly while the app runs and in the iPhone's background refresh.
@MainActor
enum EventNotifications {
    nonisolated static let category = AppIdentity.local(.eventCategory)
    /// Same as `category`, with « Rejoindre » first: categories cannot hide an action per notification.
    nonisolated static let joinCategory = AppIdentity.local(.eventJoinCategory)
    nonisolated static let leaveCategory = AppIdentity.local(.leaveCategory)
    nonisolated static let joinAction = "nuo.event.action.join"
    nonisolated static let openAction = "nuo.event.action.open"
    nonisolated static let snoozeAction = "nuo.event.action.snooze"
    nonisolated static let directionsAction = "nuo.leave.action.directions"
    nonisolated static let window: TimeInterval = 48 * 3600
    nonisolated static let alertPrefix = "event-"
    nonisolated static let leavePrefix = "leave-"
    /// Snoozes and debug samples: never reconciled away.
    nonisolated static let snoozePrefix = "snooze-event-"

    nonisolated static var notificationCategories: [UNNotificationCategory] {
        let open = UNNotificationAction(identifier: openAction, title: String(localized: "Open"), options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "calendar"))
        let snooze = UNNotificationAction(identifier: snoozeAction, title: String(localized: "In 5 min"), options: [], icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        let join = UNNotificationAction(identifier: joinAction, title: String(localized: "Join"), options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "video.fill"))
        let directions = UNNotificationAction(identifier: directionsAction, title: String(localized: "Directions"), options: [.foreground],
                                              icon: UNNotificationActionIcon(systemImageName: "arrow.triangle.turn.up.right.diamond.fill"))
        // The watch shows these actions on mirrored notifications; a summary keeps a stack of them readable.
        func make(_ id: String, _ actions: [UNNotificationAction], summary: String) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: String(localized: "Event"),
                                   categorySummaryFormat: summary, options: [.hiddenPreviewsShowTitle])
        }
        return [
            make(category, [open, snooze], summary: String(localized: "%u events")),
            make(joinCategory, [join, open, snooze], summary: String(localized: "%u events")),
            make(leaveCategory, [directions, open, snooze], summary: String(localized: "%u departures")),
        ]
    }

    /// When a « Partir maintenant » ETA should be recomputed next (the background refresh aims for it).
    private(set) static var nextTravelCheck: Date?
    private static var pendingRefresh: Task<Void, Never>?
    private static var followUp: Task<Void, Never>?
    private static var running = false
    private static var queued = false
    #if DEBUG
    private static var firedDemoSamples = false
    #endif

    // MARK: Scheduling

    static func scheduleRefresh(after delay: Duration = .seconds(2)) {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Reconciles the pending requests with what the agenda and the settings want now.
    static func refresh() async {
        if running { queued = true; return }
        running = true
        defer {
            running = false
            if queued { queued = false; scheduleRefresh(after: .milliseconds(200)) }
        }
        let center = UNUserNotificationCenter.current()
        // Before the agenda (or the places) are known, an empty plan would wipe what is scheduled.
        guard CalendarStore.shared.loaded, await center.notificationSettings().authorizationStatus.allowsDelivery else { return }
        let leaveReady = PlacesStore.shared.loaded
        let now = Date()
        let shares = NotificationBudget.quotas(reminders: RemindersStore.shared.reminders, now: now)
        TravelEstimator.shared.beginPass()
        let items = CalendarStore.shared.items
        let plans = alertPlans(items, now: now) + (leaveReady ? await leavePlans(items, now: now) : [])
        let wanted = Array(plans.sorted { $0.fire < $1.fire }.prefix(shares.events))
        let pending = await center.pendingNotificationRequests().filter {
            $0.identifier.hasPrefix(alertPrefix) || (leaveReady && $0.identifier.hasPrefix(leavePrefix))
        }
        let byId = Dictionary(wanted.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var current = Set<String>()
        var stale: [String] = []
        for request in pending {
            if let plan = byId[request.identifier], plan.matches(request) { current.insert(request.identifier) } else { stale.append(request.identifier) }
        }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for plan in wanted where !current.contains(plan.identifier) {
            try? await center.add(plan.request())
        }
        NotificationBudget.didScheduleEvents(shares)
        scheduleFollowUp(now: now)
        #if DEBUG
        if !firedDemoSamples, ProcessInfo.processInfo.arguments.contains("-fireEventNotifications") {
            firedDemoSamples = true
            await fireSamples()
        }
        #endif
    }

    private static func scheduleFollowUp(now: Date) {
        var delay: TimeInterval = 3600
        if let check = nextTravelCheck { delay = min(delay, max(check.timeIntervalSince(now), 5 * 60)) }
        followUp?.cancel()
        followUp = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Fire dates this pass would schedule (leave times estimated from the last known ETA), for the shared budget.
    static func candidateDates(now: Date) -> [Date] {
        let items = CalendarStore.shared.items
        let settings = EventAlertSettings.shared
        let places = PlacesStore.shared.places
        let alerts = alertPlans(items, now: now).map(\.fire)
        let leaves = leaveCandidates(items, now: now).compactMap { item -> Date? in
            guard let origin = settings.origin(for: item, in: places) else { return nil }
            let seconds = TravelEstimator.shared.cachedSeconds(item: item, origin: origin, mode: settings.mode) ?? item.travelTimeSec ?? 1800
            return max(now, item.start.addingTimeInterval(-TimeInterval(seconds) - settings.margin))
        }
        return alerts + leaves
    }

    // MARK: Alerts

    /// The event's alarms; for events without any, the default alert of the settings (timed events only).
    static func effectiveAlarms(_ item: AgendaItem) -> [EventAlarm] {
        if let alarms = item.alarms, !alarms.isEmpty { return alarms }
        // Gateways older than `alarms` only say whether there is one.
        if item.alarms == nil, item.hasAlarms == true { return [EventAlarm(offsetSec: -900)] }
        if !item.allDay, let minutes = EventAlertSettings.shared.defaultAlertMinutes { return [EventAlarm(offsetSec: -minutes * 60)] }
        return []
    }

    static func alertPlans(_ items: [AgendaItem], now: Date) -> [NotificationPlan] {
        guard EventAlertSettings.shared.eventsEnabled else { return [] }
        let horizon = now.addingTimeInterval(window)
        var plans: [String: NotificationPlan] = [:]
        for item in items where item.kind == .event && !item.isCancelled && item.end > now {
            for alarm in effectiveAlarms(item) {
                guard let fire = alarm.fireDate(start: item.start), fire > now, fire <= horizon else { continue }
                let id = "\(alertPrefix)\(item.id)-\(Int(fire.timeIntervalSince1970 / 60))"
                plans[id] = alertPlan(item, fire: fire, identifier: id)
            }
        }
        return Array(plans.values)
    }

    static func alertPlan(_ item: AgendaItem, fire: Date, identifier: String) -> NotificationPlan {
        let tail = alertTail(item)
        let joinable = !item.isBusyOnly && item.conference != nil
        var info: [String: String] = ["eventId": item.id, "start": NuoJSON.formatDate(item.start), "tail": tail]
        if item.allDay { info["allDay"] = "1" }
        if joinable, let url = item.conferenceUrl { info["conferenceUrl"] = url }
        return NotificationPlan(identifier: identifier, fire: fire, title: item.displayTitle,
                                body: "\(lead(start: item.start, allDay: item.allDay, at: fire)) · \(tail)",
                                category: joinable ? joinCategory : category, thread: category, info: info)
    }

    /// "2:00 PM – 3:00 PM · Café Lomi"; busy-only events never show a place.
    private static func alertTail(_ item: AgendaItem) -> String {
        var parts = [AgendaText.range(item)]
        if !item.isBusyOnly {
            if let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty, location != item.conferenceUrl {
                parts.append(location)
            } else if let url = item.conferenceUrl {
                parts.append(AgendaText.conferenceName(url))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// "In 15 min", "Now", "Tomorrow" (all-day events).
    static func lead(start: Date, allDay: Bool, at fire: Date) -> String {
        if allDay { return AgendaText.dayTitle(start) }
        let minutes = Int((start.timeIntervalSince(fire) / 60).rounded())
        if minutes < 0 { return String(localized: "Started at \(AgendaText.time(start))") }
        if minutes == 0 { return String(localized: "Now") }
        if minutes < 12 * 60 || AgendaCalendar.current.isDate(start, inSameDayAs: fire) { return String(localized: "In \(AgendaText.duration(TimeInterval(minutes * 60)))") }
        return "\(AgendaText.dayTitle(start)) \(AgendaText.time(start))"
    }

    // MARK: Leave now

    /// Timed events of the next 48 h at a physical place, unless turned off for the event.
    static func leaveCandidates(_ items: [AgendaItem], now: Date) -> [AgendaItem] {
        let settings = EventAlertSettings.shared
        guard settings.leaveEnabled else { return [] }
        let horizon = now.addingTimeInterval(window)
        return items.filter { item in
            item.kind == .event && !item.allDay && !item.isCancelled && !item.isBusyOnly && item.start > now && item.start <= horizon
                && hasPhysicalPlace(item) && settings.override(for: item)?.disabled != true
        }
    }

    private static let onlineWords = ["meet.google", "zoom", "teams", "webex", "whereby", "jit.si", "visio", "en ligne", "online", "facetime", "skype"]

    /// A place one travels to: coordinates, or an address that is not a link nor a video call.
    static func hasPhysicalPlace(_ item: AgendaItem) -> Bool {
        if item.coordinates != nil { return true }
        guard let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else { return false }
        let lower = location.lowercased()
        if lower.contains("://") || location == item.conferenceUrl { return false }
        return !onlineWords.contains { lower.contains($0) }
    }

    private static func leavePlans(_ items: [AgendaItem], now: Date) async -> [NotificationPlan] {
        let settings = EventAlertSettings.shared
        let places = PlacesStore.shared.places
        var plans: [NotificationPlan] = []
        var nextCheck: Date?
        var log = LeaveLog.load(now: now)
        for item in leaveCandidates(items, now: now) {
            guard let origin = settings.origin(for: item, in: places) else { continue }
            let outcome = await TravelEstimator.shared.estimate(item: item, origin: origin, mode: settings.mode, margin: settings.margin, now: now)
            guard case let .eta(seconds, destination) = outcome else {
                if outcome == .tooClose { await CalendarStore.shared.storeTravel(item, seconds: nil, mode: nil) }
                continue
            }
            await CalendarStore.shared.storeTravel(item, seconds: seconds, mode: settings.mode.rawValue)
            let ideal = item.start.addingTimeInterval(-TimeInterval(seconds) - settings.margin)
            let identifier = "\(leavePrefix)\(item.id)"
            let logKey = "\(identifier)@\(Int(item.start.timeIntervalSince1970))"
            var fire = ideal
            if ideal <= now {
                // Late (event added or ETA grown): say it once, right away, if there is still time to go.
                if let logged = log[logKey], logged <= now { continue }
                guard item.start.timeIntervalSince(now) > 120 else { continue }
                fire = log[logKey].map { max($0, now.addingTimeInterval(5)) } ?? now.addingTimeInterval(5)
            } else {
                let check = ideal.addingTimeInterval(-30 * 60)
                if check > now { nextCheck = min(nextCheck ?? check, check) }
            }
            log[logKey] = fire
            plans.append(leavePlan(item, seconds: seconds, mode: settings.mode, destination: destination, fire: fire, identifier: identifier))
        }
        LeaveLog.save(log)
        nextTravelCheck = nextCheck
        return plans
    }

    static func leavePlan(_ item: AgendaItem, seconds: Int, mode: TravelMode, destination: GeoPoint, fire: Date, identifier: String) -> NotificationPlan {
        var info = ["eventId": item.id, "lat": String(destination.lat), "lon": String(destination.lon), "mode": mode.rawValue]
        info["place"] = item.location
        return NotificationPlan(identifier: identifier, fire: fire, title: String(localized: "Leave now for \(item.displayTitle)"),
                                body: String(localized: "\(AgendaText.duration(TimeInterval(seconds))) \(mode.phrase) · arrive at \(AgendaText.time(item.start))"),
                                category: leaveCategory, thread: leaveCategory, info: info)
    }

    // MARK: Actions

    /// Runs a tap or an action on an event notification; false when it is not one.
    static func perform(_ response: UNNotificationResponse) async -> Bool {
        let request = response.notification.request
        let info = request.content.userInfo
        guard let eventId = info["eventId"] as? String else { return false }
        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            break
        case snoozeAction:
            await snooze(request)
        case joinAction:
            if let link = (info["conferenceUrl"] as? String).flatMap(URL.init(string:)) { PlatformApp.open(link) } else { open(eventId) }
        case directionsAction:
            if !openDirections(info) { open(eventId) }
        default:
            open(eventId)
        }
        return true
    }

    static func open(_ eventId: String) {
        WorkspaceRouter.shared.openAgendaItem(id: eventId)
    }

    private static func openDirections(_ info: [AnyHashable: Any]) -> Bool {
        guard let lat = (info["lat"] as? String).flatMap(Double.init), let lon = (info["lon"] as? String).flatMap(Double.init) else { return false }
        let destination = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
        destination.name = info["place"] as? String
        let mode = (info["mode"] as? String).flatMap(TravelMode.init(rawValue:)) ?? .driving
        destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.mapsMode])
        return true
    }

    /// The same notification in 5 min; an alert's "In 15 min" becomes "In 10 min".
    private static func snooze(_ request: UNNotificationRequest) async {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return }
        let fire = Date().addingTimeInterval(300)
        let info = request.content.userInfo
        if let start = (info["start"] as? String).flatMap(NuoJSON.parseDate), let tail = info["tail"] as? String {
            content.body = "\(lead(start: start, allDay: info["allDay"] != nil, at: fire)) · \(tail)"
        }
        let identifier = "\(snoozePrefix)\(info["eventId"] as? String ?? "")-\(Int(fire.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)))
    }

    // MARK: Debug

    #if DEBUG
    /// An alert and a “Leave now” for the next event with a place, 3 and 6 s from now (simulator checks).
    static func fireSamples() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let now = Date()
        let calendar = AgendaCalendar.current
        let start = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now.addingTimeInterval(3600)) ?? now.addingTimeInterval(3600)
        let sample = AgendaItem(kind: .event, id: "debug", title: "Team lunch", location: "Bistrot, 172 bd Saint-Germain",
                                coordinates: GeoPoint(lat: 48.8540, lon: 2.3326), start: start, end: start.addingTimeInterval(3600), allDay: false)
        let item = CalendarStore.shared.items.first { $0.kind == .event && !$0.allDay && !$0.isBusyOnly && $0.start > now && hasPhysicalPlace($0) } ?? sample
        let settings = EventAlertSettings.shared
        let alert = alertPlan(item, fire: item.start.addingTimeInterval(-15 * 60), identifier: "\(snoozePrefix)debug-alert-\(Int(now.timeIntervalSince1970))")
        try? await center.add(alert.request(after: 3))
        let seconds = item.travelTimeSec ?? 25 * 60
        let leave = leavePlan(item, seconds: seconds, mode: settings.mode, destination: item.coordinates ?? GeoPoint(lat: 48.8540, lon: 2.3326),
                              fire: now, identifier: "\(snoozePrefix)debug-leave-\(Int(now.timeIntervalSince1970))")
        try? await center.add(leave.request(after: 6))
    }
    #endif
}

/// One wanted notification, comparable with a pending request.
struct NotificationPlan {
    let identifier: String
    let fire: Date
    let title: String
    let body: String
    let category: String
    let thread: String
    let info: [String: String]

    func matches(_ request: UNNotificationRequest) -> Bool {
        guard let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return false }
        return abs(date.timeIntervalSince(fire)) < 60 && request.content.title == title && request.content.body == body
            && request.content.categoryIdentifier == category
    }

    func content() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = thread
        content.userInfo = info
        content.relevanceScore = category == EventNotifications.leaveCategory ? 1 : 0.6
        return content
    }

    func request() -> UNNotificationRequest {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        return UNNotificationRequest(identifier: identifier, content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    func request(after seconds: TimeInterval) -> UNNotificationRequest {
        UNNotificationRequest(identifier: identifier, content: content(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
    }
}

/// When each “Leave now” was scheduled to fire, so a passed one is not sent again.
private enum LeaveLog {
    private static let key = AppIdentity.local(.eventAlertsLeaveLog)

    static func load(now: Date) -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.compactMapValues { value in
            let date = Date(timeIntervalSince1970: value)
            return now.timeIntervalSince(date) < 2 * 86400 ? date : nil
        }
    }

    static func save(_ log: [String: Date]) {
        UserDefaults.standard.set(log.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}
