import Foundation
import Testing

struct DeviceToolArgsTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!

    @Test func wallClockTimesAreReadInTheDeviceZone() throws {
        let parsed = try #require(DeviceToolDate.parse("2026-10-28T09:30", timeZone: paris))
        #expect(!parsed.dayOnly)
        #expect(DeviceToolDate.format(parsed.date, timeZone: paris) == "2026-10-28T09:30:00+01:00")
        // The day before the clocks went back, Paris was still at UTC+2.
        let summer = try #require(DeviceToolDate.parse("2026-10-24T18:00", timeZone: paris))
        #expect(DeviceToolDate.format(summer.date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-24T16:00:00+00:00")
    }

    @Test func aBareDayIsAWholeDayAndAnOffsetWins() throws {
        let day = try #require(DeviceToolDate.parse("2026-12-24", timeZone: paris))
        #expect(day.dayOnly)
        #expect(DeviceToolDate.format(day.date, dayOnly: true, timeZone: paris) == "2026-12-24")
        let iso = try #require(DeviceToolDate.parse("2026-10-28T09:30:00-04:00", timeZone: paris))
        #expect(DeviceToolDate.format(iso.date, timeZone: paris) == "2026-10-28T14:30:00+01:00")
    }

    @Test func impossibleDatesAreRefusedWithAHint() {
        #expect(DeviceToolDate.parse("demain à 9h", timeZone: paris) == nil)
        #expect(DeviceToolDate.parse("2026-02-30T25:00", timeZone: paris) == nil)
        let args = DeviceToolArgs(["start": .string("jeudi prochain")])
        #expect(throws: DeviceToolError("Date invalide « jeudi prochain » pour start : utilise AAAA-MM-JJTHH:MM, ou AAAA-MM-JJ pour une journée.")) {
            try DeviceToolDate.require(args, "start", timeZone: paris)
        }
    }

    @Test func argumentsTolerateHowBotsWriteThem() {
        let args = DeviceToolArgs([
            "max": .string("12"),
            "days": .number(40),
            "all_day": .string("oui"),
            "alarms": .array([.number(10), .string("60")]),
            "calendars": .string("Famille, Travail"),
            "title": .string("  "),
            "place": .string("Ici"),
            "notes": .null,
        ])
        #expect(args.int("max", default: 8, range: 1...25) == 12)
        #expect(args.int("days", default: 3, range: 1...10) == 10)
        #expect(args.bool("all_day") == true)
        #expect(args.numbers("alarms") == [10, 60])
        #expect(args.strings("calendars") == ["Famille", "Travail"])
        #expect(args.string("title") == nil)
        #expect(args.isHere("place"))
        #expect(args.isHere("from"))
        #expect(!DeviceToolArgs(["to": .string("Gare de Lyon")]).isHere("to"))
        #expect(!args.has("notes"))
    }

    @Test func colorsRoundTripAsHex() throws {
        let c = try #require(DeviceToolColor.parse("#34C759"))
        #expect(DeviceToolColor.hex(red: c.red, green: c.green, blue: c.blue) == "#34C759")
        #expect(DeviceToolColor.parse("f80").map { DeviceToolColor.hex(red: $0.red, green: $0.green, blue: $0.blue) } == "#FF8800")
        #expect(DeviceToolColor.parse("vert") == nil)
    }

    @Test func answersDropAbsentFields() {
        let event = JSONValue.fields(["title": .string("Dentiste Dr Lefèvre"), "location": .str(nil), "allDay": nil, "lat": .rounded(48.844_312, 4)])
        #expect(event == .object(["title": .string("Dentiste Dr Lefèvre"), "lat": .number(48.8443)]))
    }
}
