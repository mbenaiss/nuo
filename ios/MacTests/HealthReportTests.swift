import Foundation
import Testing

/// Paris time, so a night and a day are the ones Alex sees in Santé.
private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}

private func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11, year: Int = 2026) -> Date {
    paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func args(_ pairs: [String: JSONValue]) -> DeviceToolArgs { DeviceToolArgs(pairs) }

struct HealthRangeTests {
    private let now = at(20, 16, 30)

    @Test func daysBackEndsOnToday() throws {
        let window = try HealthRange.window(args(["days": .number(7)]), defaultDays: 30, now: now, calendar: paris)
        #expect(window.days == 7)
        #expect(window.start == at(14))
        #expect(window.end == at(21))
        #expect(HealthRange.days(window, calendar: paris).count == 7)
    }

    @Test func withoutArgumentsTheToolsOwnDefaultApplies() throws {
        let window = try HealthRange.window(args([:]), defaultDays: 14, now: now, calendar: paris)
        #expect(window.days == 14)
        #expect(window.start == at(7))
    }

    @Test func aPeriodOfOneDayIsTheDayItself() throws {
        let window = try HealthRange.window(args(["start": .string("2026-11-18"), "end": .string("2026-11-18")]), defaultDays: 7, now: now, calendar: paris)
        #expect(window.days == 1)
        #expect(window.start == at(18))
        #expect(window.end == at(19))
    }

    @Test func startAloneRunsToToday() throws {
        let window = try HealthRange.window(args(["start": .string("2026-11-16")]), defaultDays: 7, now: now, calendar: paris)
        #expect(window.start == at(16))
        #expect(window.days == 5)
    }

    @Test func endAloneGoesBackTheToolsDefault() throws {
        let window = try HealthRange.window(args(["end": .string("2026-11-10")]), defaultDays: 3, now: now, calendar: paris)
        #expect(window.start == at(8))
        #expect(window.end == at(11))
        #expect(window.days == 3)
    }

    @Test func anEndBeforeTheStartIsRefused() {
        #expect(throws: DeviceToolError.self) {
            try HealthRange.window(args(["start": .string("2026-11-18"), "end": .string("2026-11-02")]), defaultDays: 7, now: now, calendar: paris)
        }
    }

    @Test func aPeriodLongerThanAYearIsCutBack() throws {
        let window = try HealthRange.window(args(["start": .string("2020-01-01")]), defaultDays: 7, now: now, calendar: paris)
        #expect(window.days == HealthRange.maxDays)
        #expect(window.end == at(21))
    }

    @Test func anImpossibleDateIsRefused() {
        #expect(throws: DeviceToolError.self) {
            try HealthRange.window(args(["start": .string("le 3 du mois dernier")]), defaultDays: 7, now: now, calendar: paris)
        }
    }
}

struct HealthFormatTests {
    @Test func paceReadsAsMinutesPerKilometre() {
        #expect(HealthFormat.pace(secondsPerKm: 278) == "4:38/km")
        #expect(HealthFormat.pace(secondsPerKm: 300) == "5:00/km")
        #expect(HealthFormat.pace(secondsPerKm: 0) == nil)
    }

    @Test func paceComesFromTheDistanceAndTheTime() {
        #expect(HealthFormat.pace(meters: 10_000, seconds: 2780) == "4:38/km")
        #expect(HealthFormat.pace(meters: 0, seconds: 1800) == nil)
    }

    @Test func durationSwitchesToHoursPastSixty() {
        #expect(HealthFormat.duration(seconds: 2_700) == "45 min")
        #expect(HealthFormat.duration(seconds: 4_320) == "1 h 12")
        #expect(HealthFormat.duration(seconds: 0) == "0 min")
    }

    @Test func aMissingDayIsNotAZero() {
        #expect(HealthFormat.mean([8_420, nil, 11_300]) == 9_860)
        #expect(HealthFormat.mean([nil, nil]) == nil)
        #expect(HealthFormat.total([8_420, nil, 11_300]) == 19_720)
        #expect(HealthFormat.total([nil]) == nil)
    }
}

struct HealthSleepTests {
    /// A night of 23:12 → 07:04 as Santé files it: overlapping pieces, several sources, one awake stretch.
    private let night: [SleepPiece] = [
        SleepPiece(start: at(19, 23, 12), end: at(20, 7, 4), stage: .inBed),
        SleepPiece(start: at(19, 23, 25), end: at(20, 0, 40), stage: .core),
        SleepPiece(start: at(20, 0, 40), end: at(20, 1, 55), stage: .deep),
        SleepPiece(start: at(20, 1, 55), end: at(20, 2, 35), stage: .rem),
        SleepPiece(start: at(20, 2, 35), end: at(20, 2, 48), stage: .awake),
        SleepPiece(start: at(20, 2, 48), end: at(20, 6, 50), stage: .core),
    ]

    @Test func aNightBeforeMidnightCountsForTheMorningAfter() {
        let nights = HealthSleep.nights(from: night, calendar: paris)
        #expect(nights.count == 1)
        #expect(nights[0].date == at(20))
        #expect(nights[0].fellAsleep == at(19, 23, 25))
        #expect(nights[0].wokeUp == at(20, 6, 50))
    }

    @Test func phasesAddUpAndTheAwakeStretchIsNotSleep() {
        let n = HealthSleep.nights(from: night, calendar: paris)[0]
        #expect(Int(n.deepSeconds / 60) == 75)
        #expect(Int(n.remSeconds / 60) == 40)
        #expect(Int(n.coreSeconds / 60) == 75 + 242)
        #expect(Int(n.awakeSeconds / 60) == 13)
        #expect(Int(n.inBedSeconds / 60) == 472)
        // The stages run back to back around one 13-minute waking, so the asleep total leaves it out.
        #expect(Int(n.asleepSeconds / 60) == 432)
    }

    @Test func overlappingPiecesFromTwoSourcesAreCountedOnce() {
        let doubled = night + [SleepPiece(start: at(20, 0, 40), end: at(20, 1, 55), stage: .deep)]
        let once = HealthSleep.nights(from: night, calendar: paris)[0]
        #expect(HealthSleep.nights(from: doubled, calendar: paris)[0].deepSeconds == once.deepSeconds)
    }

    @Test func aSourceWithoutPhasesStillGivesATotal() {
        let plain = [SleepPiece(start: at(19, 23, 40), end: at(20, 6, 40), stage: .asleep)]
        let n = HealthSleep.nights(from: plain, calendar: paris)[0]
        #expect(Int(n.asleepSeconds / 60) == 420)
        #expect(n.deepSeconds == 0)
    }

    @Test func anAfternoonNapBelongsToTheNextMorning() {
        let nap = [SleepPiece(start: at(18, 14, 30), end: at(18, 15, 10), stage: .core)]
        #expect(HealthSleep.nights(from: nap, calendar: paris)[0].date == at(19))
    }

    @Test func severalNightsComeBackOldestFirst() {
        let earlier = [SleepPiece(start: at(18, 23, 0), end: at(19, 6, 30), stage: .asleep)]
        let nights = HealthSleep.nights(from: earlier + night, calendar: paris)
        #expect(nights.map(\.date) == [at(19), at(20)])
    }

    @Test func anEmptyPieceIsDropped() {
        let empty = [SleepPiece(start: at(20, 3, 0), end: at(20, 3, 0), stage: .core)]
        #expect(HealthSleep.nights(from: empty, calendar: paris).isEmpty)
    }
}

struct HealthReportTests {
    private let window = HealthWindow(start: at(18), end: at(21), days: 3)

    private var days: [ActivityDay] {
        [
            ActivityDay(date: at(18), steps: 8_420, distanceMeters: 6_310, activeEnergy: 512, restingEnergy: 1_640, exerciseMinutes: 38, standMinutes: 420, flightsClimbed: 9),
            ActivityDay(date: at(19), steps: nil, distanceMeters: nil, activeEnergy: nil, restingEnergy: nil, exerciseMinutes: nil, standMinutes: nil, flightsClimbed: nil),
            ActivityDay(date: at(20), steps: 13_180, distanceMeters: 11_240, activeEnergy: 884, restingEnergy: 1_655, exerciseMinutes: 64, standMinutes: 480, flightsClimbed: 14),
        ]
    }

    @Test func aDayCarriesTheRingsWithKilometresNotMetres() throws {
        guard case let .object(day) = days[0].json(calendar: paris) else { throw DeviceToolError("pas un objet") }
        #expect(day["day"] == .string("2026-11-18"))
        #expect(day["steps"] == .number(8_420))
        #expect(day["distanceKm"] == .number(6.31))
        #expect(day["activeEnergyKcal"] == .number(512))
        #expect(day["exerciseMinutes"] == .number(38))
    }

    @Test func aDayWithoutDataCarriesOnlyItsDate() throws {
        guard case let .object(day) = days[1].json(calendar: paris) else { throw DeviceToolError("pas un objet") }
        #expect(day.keys.sorted() == ["day"])
    }

    @Test func activityAddsUpAndAveragesOverTheDaysThatHaveFigures() throws {
        guard case let .object(out) = HealthReport.activity(days, window: window, calendar: paris),
              case let .object(totals) = out["totals"], case let .object(averages) = out["averages"] else { throw DeviceToolError("pas un objet") }
        #expect(out["from"] == .string("2026-11-18"))
        #expect(out["to"] == .string("2026-11-20"))
        #expect(totals["steps"] == .number(21_600))
        #expect(totals["distanceKm"] == .number(17.6))
        #expect(averages["steps"] == .number(10_800))
        #expect(out["activity"] == .array(days.map { $0.json(calendar: paris) }))
    }

    @Test func theHeartReportCarriesItsAveragesAndVo2Max() throws {
        let heart = [
            HeartDay(date: at(19), restingHeartRate: 52, heartRateVariability: 68, walkingHeartRate: 104, minHeartRate: 46, maxHeartRate: 171, respiratoryRate: 14),
            HeartDay(date: at(20), restingHeartRate: 54, heartRateVariability: 61, walkingHeartRate: 101, minHeartRate: 48, maxHeartRate: 166, respiratoryRate: 15),
        ]
        guard case let .object(out) = HealthReport.heart(heart, vo2Max: 48.3, window: window, calendar: paris),
              case let .object(averages) = out["averages"] else { throw DeviceToolError("pas un objet") }
        #expect(averages["restingBpm"] == .number(53))
        #expect(averages["hrvMs"] == .number(65))
        #expect(out["vo2Max"] == .number(48.3))
    }

    @Test func aSessionCarriesItsPaceComputedFromDistanceAndTime() throws {
        let run = WorkoutSummary(id: "0B7D4C55-9A3E-2D8F-6B1C-7E9012345678", activity: "running", start: at(20, 7, 15), end: at(20, 8, 1),
                                 distanceMeters: 10_050, activeEnergy: 684, averageHeartRate: 158, maxHeartRate: 177, elevationMeters: 112, indoor: nil, source: "Apple Watch d'Alex")
        guard case let .object(out) = run.json(calendar: paris) else { throw DeviceToolError("pas un objet") }
        #expect(out["activity"] == .string("running"))
        #expect(out["distanceKm"] == .number(10.05))
        #expect(out["pace"] == .string("4:35/km"))
        #expect(out["durationMinutes"] == .number(46))
        #expect(out["source"] == .string("Apple Watch d'Alex"))
    }

    @Test func tooManySessionsAreFlaggedTruncated() throws {
        let session = WorkoutSummary(id: "7E901234-5678-4C55-9A3E-2D8F6B1C0B7D", activity: "cycling", start: at(19, 18, 0), end: at(19, 18, 45),
                                     distanceMeters: 21_400, activeEnergy: 520, averageHeartRate: 131, maxHeartRate: 158, elevationMeters: 240, indoor: nil, source: "Apple Watch d'Alex")
        guard case let .object(out) = HealthReport.workouts([session], window: window, truncated: true, calendar: paris),
              case let .object(totals) = out["totals"] else { throw DeviceToolError("pas un objet") }
        #expect(out["truncated"] == .bool(true))
        #expect(totals["distanceKm"] == .number(21.4))
    }

    @Test func theBodySnapshotSaysWhichWayTheWeightWent() throws {
        var body = BodySnapshot()
        body.weightKg = (value: 71.4, date: at(20, 7, 2))
        body.heightCm = (value: 178, date: at(18))
        body.vo2Max = (value: 48.3, date: at(19))
        body.weightEarlierKg = 73.2
        guard case let .object(out) = body.json(calendar: paris) else { throw DeviceToolError("pas un objet") }
        #expect(out["weightChangeKg"] == .number(-1.8))
        #expect(out["bmi"] == .number(22.5))
        guard case let .object(weight) = out["weightKg"] else { throw DeviceToolError("pas un objet") }
        #expect(weight["day"] == .string("2026-11-20"))
    }

    @Test func theSummaryPutsTodayLastNightAndTheLatestSessionsTogether() throws {
        let nights = [SleepNight(date: at(20), fellAsleep: at(19, 23, 25), wokeUp: at(20, 6, 50), asleepSeconds: 25_920, deepSeconds: 4_500, remSeconds: 2_400, coreSeconds: 19_020, awakeSeconds: 780, inBedSeconds: 28_320)]
        let heart = [HeartDay(date: at(20), restingHeartRate: 54, heartRateVariability: 61, walkingHeartRate: 101, minHeartRate: 48, maxHeartRate: 166, respiratoryRate: 15)]
        let session = WorkoutSummary(id: "2D8F6B1C-7E90-4C55-9A3E-0B7D12345678", activity: "running", start: at(20, 7, 15), end: at(20, 8, 1),
                                     distanceMeters: 10_050, activeEnergy: 684, averageHeartRate: 158, maxHeartRate: 177, elevationMeters: 112, indoor: nil, source: "Apple Watch d'Alex")
        guard case let .object(out) = HealthReport.summary(activity: days, heart: heart, nights: nights, workouts: [session], body: BodySnapshot(), window: window, calendar: paris),
              case let .object(today) = out["today"], case let .object(lastNight) = out["lastNight"] else { throw DeviceToolError("pas un objet") }
        #expect(today["day"] == .string("2026-11-20"))
        #expect(today["steps"] == .number(13_180))
        #expect(lastNight["asleep"] == .string("7 h 12"))
        #expect(out["workoutCount"] == .number(1))
        #expect(out["sleepAverageMinutes"] == .number(432))
    }
}
