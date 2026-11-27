import Foundation
import Testing

@Suite struct ReminderPendingPlanTests {
    private let due = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, _ title: String, fire: Date? = nil) -> ReminderPendingPlan.Entry {
        .init(identifier: id, fire: fire ?? due, title: title)
    }

    @Test func removesFinishedReminderScheduledUnderAnotherCategory() {
        let plan = ReminderPendingPlan.make(
            pending: [entry("reminder-rem_104", "Renouveler l'assurance habitation")],
            wanted: [])
        #expect(plan.stale == ["reminder-rem_104"])
        #expect(plan.toSchedule.isEmpty)
    }

    @Test func keepsUnchangedReminderAndSchedulesNewOne() {
        let kept = entry("reminder-rem_7", "Appeler le plombier")
        let plan = ReminderPendingPlan.make(
            pending: [kept],
            wanted: [kept, entry("reminder-rem_8", "Réserver le contrôle technique")])
        #expect(plan.stale.isEmpty)
        #expect(plan.toSchedule == ["reminder-rem_8"])
    }

    @Test func replacesReminderWhoseDateOrTitleChanged() {
        let moved = entry("reminder-rem_7", "Appeler le plombier", fire: due.addingTimeInterval(3600))
        let renamed = entry("reminder-rem_9", "Payer la cantine")
        let plan = ReminderPendingPlan.make(
            pending: [entry("reminder-rem_7", "Appeler le plombier"), renamed],
            wanted: [moved, entry("reminder-rem_9", "Payer la cantine scolaire")])
        #expect(plan.stale == ["reminder-rem_7", "reminder-rem_9"])
        #expect(plan.toSchedule == ["reminder-rem_7", "reminder-rem_9"])
    }

    @Test func leavesLocationAndOtherNotificationsAlone() {
        let plan = ReminderPendingPlan.make(
            pending: [entry("reminder-loc-rem_3", "Acheter du pain"), entry("event-evt_5-100", "Dentiste"), entry("leave-evt_5", "Dentiste")],
            wanted: [])
        #expect(plan.stale.isEmpty)
    }
}
