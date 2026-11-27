import Foundation
import Testing

struct RecurrenceWordingTests {
    @Test func reminderRepeatRulesReadInEnglishByDefault() {
        #expect(RepeatText.describe("daily") == "Every day")
        #expect(RepeatText.describe("0 9 * * *") == "Every day at 9:00")
        #expect(RepeatText.describe("30 7 * * 1-5") == "Weekdays at 7:30")
        #expect(RepeatText.describe("0 9 * * 1") == "Every Monday at 9:00")
        #expect(RepeatText.describe("0 9 15 * *") == "On day 15 of each month at 9:00")
        #expect(RepeatText.describe("not a rule") == "Recurring")
    }

    @Test func shortReminderRepeatDropsTheTime() {
        #expect(RepeatText.short("weekly") == "Weekly")
        #expect(RepeatText.short("0 9 * * *") == "Every day")
    }

    @Test func scheduleDescriptionsNameTheDaysAndTheCadence() {
        let weekdays = TaskSchedule(kind: "cron", expr: "0 8 * * 1-5", timezone: "Europe/Paris", at: nil)
        #expect(ScheduleText.describe(weekdays) == "Mon-Fri at 8:00")
        let weekend = TaskSchedule(kind: "cron", expr: "30 10 * * 0,6", timezone: "Europe/Paris", at: nil)
        #expect(ScheduleText.describe(weekend) == "Weekends at 10:30")
        let everyTwoHours = TaskSchedule(kind: "cron", expr: "15 */2 * * *", timezone: "Europe/Paris", at: nil)
        #expect(ScheduleText.describe(everyTwoHours) == "Every 2 h, at :15")
    }

    @Test func relativeRunTimesUseShortEnglishPhrases() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ScheduleText.relative(now.addingTimeInterval(30), now: now) == "imminent")
        #expect(ScheduleText.relative(now.addingTimeInterval(25 * 60), now: now) == "in 25 min")
        #expect(ScheduleText.countdown(now.addingTimeInterval(3 * 3600), now: now) == "in 3 h")
        #expect(ScheduleText.countdown(now.addingTimeInterval(3 * 86400), now: now) == "in 3 d")
    }
}
