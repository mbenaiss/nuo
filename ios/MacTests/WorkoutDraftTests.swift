import Foundation
import Testing

private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}

/// A 6 × 800 m at 3:50 with 2 min of jogging between, as a bot would compose it for Alex.
private let intervals: [String: JSONValue] = [
    "name": .string("6 × 800 m à 3:50"),
    "sport": .string("running"),
    "warmup": .object(["minutes": .number(15), "pace_fast": .string("5:30"), "pace_slow": .string("6:10"), "name": .string("Échauffement")]),
    "blocks": .array([
        .object([
            "repeat": .number(6),
            "steps": .array([
                .object(["distance": .number(800), "pace": .string("3:50"), "name": .string("800 m")]),
                .object(["purpose": .string("recovery"), "minutes": .number(2), "heart_rate_max": .number(145), "name": .string("Trot")]),
            ]),
        ]),
    ]),
    "cooldown": .object(["km": .number(2), "pace_slow": .string("6:30"), "name": .string("Retour au calme")]),
]

struct WorkoutDraftParserTests {
    private let now = paris.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 30))!

    @Test func aSessionOfIntervalsIsReadWholeWithItsRepetitions() throws {
        let draft = try WorkoutDraftParser.parse(DeviceToolArgs(intervals), now: now, calendar: paris)
        #expect(draft.name == "6 × 800 m à 3:50")
        #expect(draft.sport == .running)
        #expect(draft.place == .outdoor)
        #expect(draft.blocks.count == 1)
        #expect(draft.blocks[0].iterations == 6)
        #expect(draft.blocks[0].steps.map(\.purpose) == [.work, .recovery])
        #expect(draft.warmup?.goal == .time(seconds: 900))
        #expect(draft.cooldown?.goal == .distance(meters: 2_000))
        // 15 min of warm-up, 6 × (800 m at 3:50 + 2 min), 2 km at 6:30.
        #expect(draft.stepCount == 1 + 12 + 1)
        #expect(Int((draft.estimatedSeconds ?? 0) / 60) == 15 + 6 * 5 + 13)
    }

    @Test func theSummaryReadsAsASentence() throws {
        let draft = try WorkoutDraftParser.parse(DeviceToolArgs(intervals), now: now, calendar: paris)
        #expect(draft.summary.contains("6 × (800 m · 800 m · 3:50/km puis Trot"))
        #expect(draft.summary.hasPrefix("échauffement : Échauffement · 15 min · 5:30/km à 6:10/km"))
    }

    @Test func aPaceRangeKeepsTheQuickEndFirst() throws {
        let step = try WorkoutDraftParser.step(DeviceToolArgs(["km": .number(10), "pace_slow": .string("4:50"), "pace_fast": .string("4:30")]), purpose: .work, what: "bloc")
        #expect(step.target == .paceRange(fast: 270, slow: 290))
    }

    @Test func thesamePaceTwiceBecomesASingleTarget() throws {
        let step = try WorkoutDraftParser.step(DeviceToolArgs(["km": .number(5), "pace_fast": .string("4:30"), "pace_slow": .string("4:30")]), purpose: .work, what: "bloc")
        #expect(step.target == .pace(secondsPerKm: 270))
    }

    @Test func aHeartRateCeilingAloneIsAllowed() throws {
        let step = try WorkoutDraftParser.step(DeviceToolArgs(["minutes": .number(40), "heart_rate_max": .number(145)]), purpose: .recovery, what: "bloc")
        #expect(step.target == .heartRateCeiling(145))
    }

    @Test func aHeartRateRangeNeedsItsBoundsInOrder() {
        #expect(throws: DeviceToolError.self) {
            try WorkoutDraftParser.step(DeviceToolArgs(["minutes": .number(30), "heart_rate_min": .number(160), "heart_rate_max": .number(140)]), purpose: .work, what: "bloc")
        }
    }

    @Test func aZoneOutsideOneToFiveIsRefused() {
        #expect(throws: DeviceToolError.self) {
            try WorkoutDraftParser.step(DeviceToolArgs(["minutes": .number(30), "heart_rate_zone": .number(7)]), purpose: .work, what: "bloc")
        }
    }

    @Test func aStepWithoutAnEndIsRefused() {
        #expect(throws: DeviceToolError.self) {
            try WorkoutDraftParser.step(DeviceToolArgs(["pace": .string("4:30")]), purpose: .work, what: "bloc")
        }
    }

    @Test func anOpenStepRunsUntilTheWristIsTapped() throws {
        let step = try WorkoutDraftParser.step(DeviceToolArgs(["open": .bool(true)]), purpose: .work, what: "bloc")
        #expect(step.goal == .open)
    }

    @Test func pacesAreReadInEveryShapeABotWrites() throws {
        #expect(try WorkoutDraftParser.pace("4:30", what: "bloc") == 270)
        #expect(try WorkoutDraftParser.pace("4:30/km", what: "bloc") == 270)
        #expect(try WorkoutDraftParser.pace(" 285 ", what: "bloc") == 285)
    }

    @Test func anAbsurdPaceIsRefused() {
        #expect(throws: DeviceToolError.self) { try WorkoutDraftParser.pace("0:45", what: "bloc") }
        #expect(throws: DeviceToolError.self) { try WorkoutDraftParser.pace("quatre minutes trente", what: "bloc") }
    }

    @Test func anEmptySessionIsRefused() {
        #expect(throws: DeviceToolError.self) {
            try WorkoutDraftParser.parse(DeviceToolArgs(["name": .string("Sortie du jeudi")]), now: now, calendar: paris)
        }
    }

    @Test func aSessionWithoutANameIsRefused() {
        #expect(throws: DeviceToolError.self) {
            try WorkoutDraftParser.parse(DeviceToolArgs(["blocks": .array([.object(["steps": .array([.object(["km": .number(10)])])])])]), now: now, calendar: paris)
        }
    }

    @Test func anUnknownSportIsRefused() {
        var bad = intervals
        bad["sport"] = .string("escalade")
        #expect(throws: DeviceToolError.self) { try WorkoutDraftParser.parse(DeviceToolArgs(bad), now: now, calendar: paris) }
    }

    @Test func pastFiftyStepsTheSessionIsRefusedAsTheWatchWould() {
        var long = intervals
        long["blocks"] = .array([.object(["repeat": .number(30), "steps": .array([.object(["distance": .number(400), "pace": .string("3:40")]), .object(["purpose": .string("recovery"), "minutes": .number(1)])])])])
        #expect(throws: DeviceToolError.self) { try WorkoutDraftParser.parse(DeviceToolArgs(long), now: now, calendar: paris) }
    }

    @Test func aBlockWithoutStepsIsRefused() {
        var bad = intervals
        bad["blocks"] = .array([.object(["repeat": .number(4), "steps": .array([])])])
        #expect(throws: DeviceToolError.self) { try WorkoutDraftParser.parse(DeviceToolArgs(bad), now: now, calendar: paris) }
    }

    @Test func aDateInThePastBecomesNowSoTheSessionShowsUp() throws {
        let date = try WorkoutDraftParser.date(DeviceToolArgs(["date": .string("2026-11-02T07:00")]), now: now, calendar: paris)
        #expect(date == now)
    }

    @Test func aBareDayMeansThatMorning() throws {
        let date = try WorkoutDraftParser.date(DeviceToolArgs(["date": .string("2026-11-22")]), now: now, calendar: paris)
        #expect(date == paris.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9))!)
    }

    @Test func noDateLetsTheSessionStartNow() throws {
        #expect(try WorkoutDraftParser.date(DeviceToolArgs([:]), now: now, calendar: paris) == nil)
    }

    @Test func theAnswerToTheBotNamesThePlanAndItsLength() throws {
        let draft = try WorkoutDraftParser.parse(DeviceToolArgs(intervals), now: now, calendar: paris)
        guard case let .object(out) = draft.json() else { throw DeviceToolError("pas un objet") }
        #expect(out["name"] == .string("6 × 800 m à 3:50"))
        #expect(out["sport"] == .string("running"))
        #expect(out["steps"] == .number(14))
        #expect(out["estimatedMinutes"] == .number(58))
    }
}
