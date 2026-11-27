import Foundation
import Testing

private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}

/// "Upper body" as the Coach saved it: two supersets of Matrix machines, 3 sets, planned on Tuesday.
private let upperBody = MuscuSession(
    id: 101, name: "Upper body", note: "Do the blocks in any order.",
    blocks: [
        MuscuBlock(exercises: [
            MuscuExercise(name: "Chest Press", reps: 10, alts: ["Pec Fly"]),
            MuscuExercise(name: "Seated Row", reps: 10, alts: ["Seated Cable Row"]),
        ]),
        MuscuBlock(exercises: [
            MuscuExercise(name: "Lat Pulldown", reps: 10, alts: ["Cable Lat Pulldown"]),
            MuscuExercise(name: "Lateral Raise", reps: 15, alts: []),
        ]),
    ],
    sets: 3, rest: 75, restBlock: 120, rir: 2, days: [2])

private let legs = MuscuSession(
    id: 102, name: "Legs and core", note: "",
    blocks: [MuscuBlock(exercises: [MuscuExercise(name: "Leg Press", reps: 10, alts: ["Hack Squat"])])],
    sets: 3, rest: 75, restBlock: 120, rir: 2, days: [4])

struct MuscuRunTests {
    /// Tuesday 8 September 2026, 18:45 in Paris.
    private let tuesday = paris.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 18, minute: 45))!

    @Test func theSessionPlannedTodayOpensElseTheLastOneElseTheNewest() {
        let thursday = tuesday.addingTimeInterval(2 * 86_400)
        let saturday = tuesday.addingTimeInterval(4 * 86_400)
        #expect(MuscuPlan.isoWeekday(tuesday, calendar: paris) == 2)
        #expect(MuscuPlan.pick([legs, upperBody], date: tuesday, lastId: nil, calendar: paris)?.id == 101)
        #expect(MuscuPlan.pick([legs, upperBody], date: thursday, lastId: 101, calendar: paris)?.id == 102)
        #expect(MuscuPlan.pick([legs, upperBody], date: saturday, lastId: 101, calendar: paris)?.id == 101)
        #expect(MuscuPlan.pick([legs, upperBody], date: saturday, lastId: nil, calendar: paris)?.id == 102)
        #expect(MuscuPlan.pick([], date: saturday, lastId: nil, calendar: paris) == nil)
    }

    @Test func aNewRunIsPrefilledWithTheLastLoads() {
        let loads = MuscuLoads(gateway: ["Chest Press": MuscuLastLoad(kg: 30, reps: 10, day: "2026-09-01")])
        let run = MuscuRun(session: upperBody, loads: loads, now: tuesday, id: "run-2026-09-08-1845")
        let first = run.exercises(of: 0, in: upperBody)
        #expect(first.map(\.kg) == [30, nil])
        #expect(first.map(\.reps) == [10, 10])
        #expect(run.stepLabel(in: upperBody) == "Block A · set 1/3")
    }

    @Test func aSetRestsWithinTheBlockThenLongerWhenMovingToTheNext() {
        var loads = MuscuLoads()
        var run = MuscuRun(session: upperBody, loads: loads, now: tuesday, id: "run-2026-09-08-1845")
        run.setKg(30, key: "0.0")
        run.completeSet(in: upperBody, loads: &loads, now: tuesday)
        #expect(run.rest == MuscuRun.Rest(until: tuesday.addingTimeInterval(75), total: 75, kind: .set))
        #expect(loads.kg(for: "chest press") == 30)
        run.completeSet(in: upperBody, loads: &loads, now: tuesday.addingTimeInterval(150))
        run.completeSet(in: upperBody, loads: &loads, now: tuesday.addingTimeInterval(300))
        #expect(run.current == 1)
        #expect(run.rest?.kind == .block)
        #expect(run.rest?.total == 120)
        #expect(run.stepLabel(in: upperBody) == "Block B · set 1/3")
    }

    @Test func blocksGoInAnyOrderAndTheLastSetEndsTheSession() {
        var loads = MuscuLoads()
        var run = MuscuRun(session: upperBody, loads: loads, now: tuesday, id: "run-2026-09-08-1845")
        run.switchBlock(to: 1)
        for i in 0..<3 { run.completeSet(in: upperBody, loads: &loads, now: tuesday.addingTimeInterval(Double(i) * 120)) }
        #expect(run.current == 0)
        run.skipSet(in: upperBody, now: tuesday.addingTimeInterval(400))
        #expect(run.rest == nil)
        run.completeSet(in: upperBody, loads: &loads, now: tuesday.addingTimeInterval(500))
        run.completeSet(in: upperBody, loads: &loads, now: tuesday.addingTimeInterval(1934))
        #expect(run.isFinished)
        #expect(run.realOrder == [1, 0])
        #expect(run.setsDone == 5)
        #expect(run.rest == nil)
    }

    @Test func aTakenMachineIsReplacedWithItsOwnLoadAndTheOriginalBecomesTheWayBack() {
        let loads = MuscuLoads(gateway: ["Pec Fly": MuscuLastLoad(kg: 32.5, reps: 12, day: "2026-09-01")])
        var run = MuscuRun(session: upperBody, loads: loads, now: tuesday, id: "run-2026-09-08-1845")
        run.replaceExercise(block: 0, exercise: 0, with: "Pec Fly", in: upperBody, loads: loads)
        let swapped = run.exercises(of: 0, in: upperBody)[0]
        #expect(swapped.name == "Pec Fly")
        #expect(swapped.swapped)
        #expect(swapped.kg == 32.5)
        #expect(swapped.alts == ["Chest Press"])
        run.replaceExercise(block: 0, exercise: 0, with: "Chest Press", in: upperBody, loads: loads)
        #expect(!run.exercises(of: 0, in: upperBody)[0].swapped)
    }

    @Test func theFinishedSessionIsSentWithItsLocalDayAndWhatWasLifted() throws {
        var loads = MuscuLoads()
        var run = MuscuRun(session: upperBody, loads: loads, now: tuesday, id: "run-2026-09-08-1845")
        run.replaceExercise(block: 0, exercise: 0, with: "Pec Fly", in: upperBody, loads: loads)
        run.setKg(32.5, key: "0.0")
        run.setReps(12, key: "0.0")
        run.completeSet(in: upperBody, loads: &loads, now: tuesday.addingTimeInterval(60))
        run.finish(now: tuesday.addingTimeInterval(1934))
        let body = run.finishedBody(calendar: paris)
        #expect(body.day == "2026-09-08")
        #expect(body.seconds == 1934)
        #expect(body.sessionId == 101)
        #expect(body.sets == [MuscuFinishedBody.DoneSet(block: 0, exercises: [
            .init(name: "Pec Fly", base: "Chest Press", reps: 12, kg: 32.5),
            .init(name: "Seated Row", base: "Seated Row", reps: 10, kg: nil),
        ])])
    }

    @Test func aSavedRunResumesUnlessForgottenOrItsSessionChanged() throws {
        var run = MuscuRun(session: upperBody, loads: MuscuLoads(), now: tuesday, id: "run-2026-09-08-1845")
        var loads = MuscuLoads()
        run.completeSet(in: upperBody, loads: &loads, now: tuesday)
        let data = try JSONEncoder().encode(run)
        let resumed = MuscuRun.restore(data, sessions: [upperBody], now: tuesday.addingTimeInterval(30))
        #expect(resumed == run)
        // The rest ran out while the app was closed.
        #expect(MuscuRun.restore(data, sessions: [upperBody], now: tuesday.addingTimeInterval(90))?.rest == nil)
        #expect(MuscuRun.restore(data, sessions: [upperBody], now: tuesday.addingTimeInterval(5 * 3600)) == nil)
        var shorter = upperBody
        shorter.blocks.removeLast()
        #expect(MuscuRun.restore(data, sessions: [shorter], now: tuesday) == nil)
        #expect(MuscuRun.restore(data, sessions: [legs], now: tuesday) == nil)
    }

    @Test func formats() {
        #expect(MuscuFormat.kg(32.5, locale: Locale(identifier: "en_US")) == "32.5")
        #expect(MuscuFormat.kg(32.5, locale: Locale(identifier: "fr_FR")) == "32,5")
        #expect(MuscuFormat.kg(30, locale: Locale(identifier: "fr_FR")) == "30")
        #expect(MuscuFormat.clock(75) == "1:15")
        #expect(MuscuFormat.clock(3725) == "1:02:05")
        #expect(MuscuFormat.summary(upperBody) == "2 blocks × 3 sets · rest 1:15 / 2:00 · 2 reps in reserve")
        #expect(MuscuFormat.letter(3) == "D")
    }

    @Test func theRestTravelsToTheWatchAndOnlyThere() throws {
        let rest = MuscuRestLink.Rest(until: tuesday.addingTimeInterval(75), total: 75, title: "Rest", next: "Block A · set 2/3")
        let start = MuscuRestLink.payload(rest, sentAt: tuesday)
        #expect(MuscuRestLink.decode(start) == .start(rest, sentAt: tuesday))
        #expect(MuscuRestLink.decode(MuscuRestLink.payload(nil, sentAt: tuesday)) == .stop(sentAt: tuesday))
        #expect(MuscuRestLink.decode(["kind": "segment", "recordingId": "r1"]) == nil)
    }
}
