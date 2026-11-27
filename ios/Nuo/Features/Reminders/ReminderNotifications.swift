import Foundation
import UserNotifications

/// Category `nuo.reminder` (Fait / +1 h / Demain 9 h) for the gateway's pushes and the local fallback.
/// Local requests use the push's collapse id (`reminder-<id>`) as identifier, so the remote push replaces them.
enum ReminderNotifications {
    static let category = "nuo.reminder"
    static let doneAction = "nuo.reminder.done"
    static let snoozeAction = "nuo.reminder.snooze"
    static let tomorrowAction = "nuo.reminder.tomorrow"
    static let window: TimeInterval = 48 * 3600

    static func identifier(_ reminderId: String) -> String { "reminder-\(reminderId)" }

    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: doneAction, title: String(localized: "Done"), options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")),
            UNNotificationAction(identifier: snoozeAction, title: String(localized: "+1 h"), options: [], icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")),
            UNNotificationAction(identifier: tomorrowAction, title: String(localized: "Tomorrow 9 AM"), options: [], icon: UNNotificationActionIcon(systemImageName: "sunrise")),
        ], intentIdentifiers: [])
    }

    static func tomorrowMorning(from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Due dates of the reminders to notify within 48 h, soonest first.
    static func candidateDates(_ reminders: [Reminder], now: Date) -> [Date] {
        due(reminders, now: now).compactMap(\.effectiveDate)
    }

    private static func due(_ reminders: [Reminder], now: Date) -> [Reminder] {
        reminders.filter { reminder in
            guard !reminder.isDone, let date = reminder.effectiveDate else { return false }
            return date > now && date.timeIntervalSince(now) <= window
        }
        .sorted { ($0.effectiveDate ?? .distantFuture) < ($1.effectiveDate ?? .distantFuture) }
    }

    /// Keeps one pending local notification per reminder due within 48 h (soonest first, within the share
    /// `NotificationBudget` gives reminders), and none for the others.
    @MainActor static func sync(_ reminders: [Reminder]) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status.allowsDelivery else { return }
        let now = Date()
        let shares = NotificationBudget.quotas(reminders: reminders, now: now)
        let wanted = Array(due(reminders, now: now).prefix(shares.reminders))
        NotificationBudget.didScheduleReminders(shares)
        await LocationTriggers.sync(reminders)
        let pending = await center.pendingNotificationRequests().map {
            ReminderPendingPlan.Entry(identifier: $0.identifier, fire: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(), title: $0.content.title)
        }
        let plan = ReminderPendingPlan.make(pending: pending, wanted: wanted.map {
            ReminderPendingPlan.Entry(identifier: identifier($0.id), fire: $0.effectiveDate, title: $0.title)
        })
        if !plan.stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: plan.stale) }
        for reminder in wanted where plan.toSchedule.contains(identifier(reminder.id)) {
            guard let date = reminder.effectiveDate else { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.notes?.isEmpty == false ? reminder.notes! : String(localized: "Reminder · \(reminder.list)")
            content.sound = .default
            content.categoryIdentifier = category
            content.threadIdentifier = category
            content.userInfo = ["reminderId": reminder.id]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(identifier: identifier(reminder.id), content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    static func cancel(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [identifier(id)])
        LocationTriggers.cancel(id)
    }

    /// API usable when an action arrives before the app finished launching.
    @MainActor static func api() -> (any NuoAPI)? {
        if let api = PushManager.shared.api { return api }
        if ProcessInfo.processInfo.arguments.contains("-demo") { return nil }
        let url = AppIdentity.gatewayURL
        guard let auth = AuthSession.restore(fallbackLAN: url) else { return nil }
        return NuoClient(baseURL: url, auth: auth)
    }

    /// Runs a notification action on the reminder; returns false when the action is not one of ours.
    @MainActor static func perform(action: String, reminderId: String) async -> Bool {
        guard [doneAction, snoozeAction, tomorrowAction].contains(action) else { return false }
        guard let api = api() else { return true }
        cancel(reminderId)
        let updated: Reminder?
        switch action {
        case doneAction: updated = try? await api.setReminderDone(id: reminderId, done: true)
        case snoozeAction: updated = try? await api.snoozeReminder(id: reminderId, until: Date().addingTimeInterval(3600))
        default: updated = try? await api.snoozeReminder(id: reminderId, until: tomorrowMorning())
        }
        if let updated { RemindersStore.shared.apply(updated) }
        return true
    }
}
