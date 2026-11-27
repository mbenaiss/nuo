import Foundation
import Testing

struct WidgetRemindersTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func paris(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { paris(28, 14) }

    private var snapshot: WidgetRemindersSnapshot {
        let items = [
            ReminderWireItem(id: "plumber", title: "Appeler le plombier", dueAt: paris(28, 18), list: "Maison", priority: 0),
            ReminderWireItem(id: "insurance", title: "Renouveler l'assurance auto", dueAt: paris(30, 10), list: "Admin", priority: 1),
            ReminderWireItem(id: "tax", title: "Déclarer la taxe foncière", dueAt: paris(27, 9), list: "Admin", priority: 2),
            ReminderWireItem(id: "pharmacy", title: "Passer à la pharmacie", dueAt: paris(28, 23, 59), list: "Perso", priority: 0),
            ReminderWireItem(id: "tires", title: "Prendre rdv pour les pneus hiver", dueAt: paris(29, 0), list: "Voiture", priority: 0),
            ReminderWireItem(id: "books", title: "Trier la bibliothèque", list: "Maison", priority: 0),
            ReminderWireItem(id: "parcel", title: "Récupérer le colis La Poste", dueAt: paris(28, 9), list: "Perso", priority: 0, doneAt: paris(28, 10)),
            ReminderWireItem(id: "boiler", title: "Faire entretenir la chaudière", dueAt: paris(26, 9), snoozedUntil: paris(31, 9), list: "Maison", priority: 0),
        ]
        return WidgetRemindersSnapshot(status: .ready, items: items, fetchedAt: now)
    }

    @Test func todayScopeListsOnlyOpenRemindersDueBeforeMidnightWithOverdueFirst() {
        let shown = snapshot.visible(at: now, limit: 10, scope: .today, calendar: calendar)
        #expect(shown.map(\.id) == ["tax", "plumber", "pharmacy"])
    }

    @Test func todayAndUpcomingScopeFillsTheSpaceWithTheComingReminders() {
        let shown = snapshot.visible(at: now, limit: 10, scope: .todayAndUpcoming, calendar: calendar)
        #expect(shown.map(\.id) == ["tax", "plumber", "pharmacy", "tires", "insurance", "boiler"])
        #expect(snapshot.visible(at: now, limit: 4, scope: .todayAndUpcoming, calendar: calendar).count == 4)
    }

    @Test func todayScopeHasNoUpcomingSection() {
        #expect(snapshot.upcoming(at: now, scope: .today, calendar: calendar).isEmpty)
        #expect(snapshot.upcoming(at: now, scope: .todayAndUpcoming, calendar: calendar).map(\.id) == ["tires", "insurance", "boiler"])
    }

    @Test func todayScopeIsEmptyWhenNothingIsDueToday() {
        let onlyLater = WidgetRemindersSnapshot(status: .ready, items: [
            ReminderWireItem(id: "insurance", title: "Renouveler l'assurance auto", dueAt: paris(30, 10), list: "Admin", priority: 1),
        ], fetchedAt: now)
        #expect(onlyLater.visible(at: now, limit: 3, scope: .today, calendar: calendar).isEmpty)
    }

    @Test func tomorrowsRemindersBecomeTodaysAtMidnight() {
        let shown = snapshot.visible(at: paris(29, 0), limit: 10, scope: .today, calendar: calendar)
        #expect(shown.map(\.id) == ["tax", "plumber", "pharmacy", "tires"])
    }
}
