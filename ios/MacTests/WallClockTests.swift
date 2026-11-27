import Foundation
import Testing

/// Paris goes back from UTC+2 to UTC+1 on 25 October 2026: that day lasts 25 hours.
struct WallClockTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func paris(_ text: String) throws -> Date {
        try #require(DeviceToolDate.parse(text, timeZone: calendar.timeZone)).date
    }

    private func format(_ date: Date) -> String {
        DeviceToolDate.format(date, timeZone: calendar.timeZone)
    }

    @Test func eventsSitAtTheirClockTimeOnTheDayTheClocksGoBack() throws {
        let day = try paris("2026-10-25")
        let dentist = try paris("2026-10-25T10:00")
        #expect(WallClock.minutes(of: dentist, on: day, calendar: calendar) == 600)
        #expect(WallClock.minutes(of: try paris("2026-10-26"), on: day, calendar: calendar) == 1440)
        #expect(WallClock.minutes(of: try paris("2026-10-24T22:00"), on: day, calendar: calendar) == 0)
    }

    @Test func aSlotDrawnInTheGridKeepsItsClockTime() throws {
        let day = try paris("2026-10-25")
        #expect(format(WallClock.date(on: day, minutes: 600, calendar: calendar)) == "2026-10-25T10:00:00+01:00")
        #expect(format(WallClock.date(on: day, minutes: 1440, calendar: calendar)) == "2026-10-26T00:00:00+01:00")
    }

    @Test func draggingToTheNextDayKeepsTheClockTime() throws {
        let standup = try paris("2026-10-24T09:00")
        #expect(format(WallClock.shift(standup, days: 1, minutes: 30, calendar: calendar)) == "2026-10-25T09:30:00+01:00")
        #expect(format(WallClock.shift(standup, days: 0, minutes: -15, calendar: calendar)) == "2026-10-24T08:45:00+02:00")
    }

    @Test func aWeeklyRepetitionFollowsTheStartToItsNewDay() throws {
        let saturday = try paris("2026-10-24T10:00"), monday = try paris("2026-10-26T10:00")
        #expect(WallClock.weekdays([6], movingFrom: saturday, to: monday, calendar: calendar) == [1])
        #expect(WallClock.weekdays([1, 3], movingFrom: saturday, to: monday, calendar: calendar) == [1, 3])
    }

    @Test func allDayEndsStayOnMidnightAcrossTheChange() throws {
        let sunday = try paris("2026-10-25")
        let end = WallClock.exclusiveEnd(fromInclusiveDay: sunday, calendar: calendar)
        #expect(format(end) == "2026-10-26T00:00:00+01:00")
        #expect(WallClock.inclusiveDay(fromExclusiveEnd: end, calendar: calendar) == sunday)
        let moved = WallClock.end(keeping: try paris("2026-10-24"), try paris("2026-10-25"), newStart: sunday, allDay: true, minimum: 900, calendar: calendar)
        #expect(format(moved) == "2026-10-26T00:00:00+01:00")
    }

    @Test func aTimedEventKeepsItsDurationWhenItsStartMoves() throws {
        let end = WallClock.end(keeping: try paris("2026-10-24T14:00"), try paris("2026-10-24T15:30"), newStart: try paris("2026-10-27T09:00"),
                                allDay: false, minimum: 900, calendar: calendar)
        #expect(format(end) == "2026-10-27T10:30:00+01:00")
    }
}
