import Foundation

/// The period a `health_*` tool reads.
struct HealthWindow: Equatable, Sendable {
    let start: Date
    /// Exclusive: the start of the day after the last one read.
    let end: Date
    let days: Int
}

/// Turns the `days` / `start` / `end` arguments of the health tools into whole local days.
enum HealthRange {
    static let maxDays = 400

    static func window(_ args: DeviceToolArgs, defaultDays: Int, key: String = "days", now: Date = Date(), calendar: Calendar = .current) throws -> HealthWindow {
        let today = calendar.startOfDay(for: now)
        let startArg = try DeviceToolDate.require(args, "start")
        let endArg = try DeviceToolDate.require(args, "end")
        if startArg == nil, endArg == nil {
            let days = args.int(key, default: defaultDays, range: 1...maxDays)
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            return window(start: start, lastDay: today, calendar: calendar)
        }
        let lastDay = calendar.startOfDay(for: endArg?.date ?? now)
        let start = calendar.startOfDay(for: startArg?.date ?? calendar.date(byAdding: .day, value: -(defaultDays - 1), to: lastDay) ?? lastDay)
        guard lastDay >= start else { throw DeviceToolError("end doit être après start.") }
        return window(start: start, lastDay: lastDay, calendar: calendar)
    }

    private static func window(start: Date, lastDay: Date, calendar: Calendar) -> HealthWindow {
        let span = (calendar.dateComponents([.day], from: start, to: lastDay).day ?? 0) + 1
        let days = min(max(span, 1), maxDays)
        let first = days == span ? start : calendar.date(byAdding: .day, value: -(days - 1), to: lastDay) ?? start
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        return HealthWindow(start: first, end: end, days: days)
    }

    /// The local days of the window, oldest first.
    static func days(_ window: HealthWindow, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var day = window.start
        while day < window.end, out.count < maxDays {
            out.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }
}

/// How health figures reach the bots: numbers rounded the way one reads them, French names for the rest.
enum HealthFormat {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        DeviceToolDate.format(date, dayOnly: true, timeZone: calendar.timeZone)
    }

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        DeviceToolDate.format(date, timeZone: calendar.timeZone)
    }

    /// Minutes and seconds per kilometre, as a runner reads a pace.
    static func pace(secondsPerKm: Double) -> String? {
        guard secondsPerKm.isFinite, secondsPerKm > 0, secondsPerKm < 36_000 else { return nil }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d/km", total / 60, total % 60)
    }

    static func pace(meters: Double, seconds: Double) -> String? {
        guard meters > 0, seconds > 0 else { return nil }
        return pace(secondsPerKm: seconds / (meters / 1000))
    }

    static func duration(seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }

    static func rounded(_ value: Double?, _ places: Int) -> JSONValue? {
        guard let value, value.isFinite else { return nil }
        return .rounded(value, places)
    }

    /// Averages over the days that have a figure: a missing day is not a zero.
    static func mean(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    static func total(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

/// One day of the rings: what the iPhone and the watch counted.
struct ActivityDay: Equatable, Sendable {
    let date: Date
    var steps: Double?
    var distanceMeters: Double?
    var activeEnergy: Double?
    var restingEnergy: Double?
    var exerciseMinutes: Double?
    var standMinutes: Double?
    var flightsClimbed: Double?

    func json(calendar: Calendar = .current) -> JSONValue {
        .fields([
            "day": .string(HealthFormat.day(date, calendar: calendar)),
            "steps": HealthFormat.rounded(steps, 0),
            "distanceKm": HealthFormat.rounded(distanceMeters.map { $0 / 1000 }, 2),
            "activeEnergyKcal": HealthFormat.rounded(activeEnergy, 0),
            "restingEnergyKcal": HealthFormat.rounded(restingEnergy, 0),
            "exerciseMinutes": HealthFormat.rounded(exerciseMinutes, 0),
            "standMinutes": HealthFormat.rounded(standMinutes, 0),
            "flightsClimbed": HealthFormat.rounded(flightsClimbed, 0),
        ])
    }
}

/// One day of the heart: the figures Santé computes per day, not the raw beats.
struct HeartDay: Equatable, Sendable {
    let date: Date
    var restingHeartRate: Double?
    var heartRateVariability: Double?
    var walkingHeartRate: Double?
    var minHeartRate: Double?
    var maxHeartRate: Double?
    var respiratoryRate: Double?

    func json(calendar: Calendar = .current) -> JSONValue {
        .fields([
            "day": .string(HealthFormat.day(date, calendar: calendar)),
            "restingBpm": HealthFormat.rounded(restingHeartRate, 0),
            "hrvMs": HealthFormat.rounded(heartRateVariability, 0),
            "walkingBpm": HealthFormat.rounded(walkingHeartRate, 0),
            "minBpm": HealthFormat.rounded(minHeartRate, 0),
            "maxBpm": HealthFormat.rounded(maxHeartRate, 0),
            "breathsPerMinute": HealthFormat.rounded(respiratoryRate, 0),
        ])
    }
}

/// A piece of sleep as Santé stores it: one stage, from one source, over one stretch of time.
struct SleepPiece: Equatable, Sendable {
    enum Stage: String, Sendable, CaseIterable {
        case awake, core, deep, rem, asleep, inBed
    }

    let start: Date
    let end: Date
    let stage: Stage

    var seconds: Double { max(0, end.timeIntervalSince(start)) }
}

/// One night, pieces of sleep merged into the figures a bot reads.
struct SleepNight: Equatable, Sendable {
    /// The day the night belongs to: the morning one wakes up.
    let date: Date
    let fellAsleep: Date?
    let wokeUp: Date?
    var asleepSeconds: Double
    var deepSeconds: Double
    var remSeconds: Double
    var coreSeconds: Double
    var awakeSeconds: Double
    var inBedSeconds: Double

    func json(calendar: Calendar = .current) -> JSONValue {
        .fields([
            "day": .string(HealthFormat.day(date, calendar: calendar)),
            "asleep": .str(HealthFormat.duration(seconds: asleepSeconds)),
            "asleepMinutes": HealthFormat.rounded(asleepSeconds / 60, 0),
            "fellAsleep": .str(fellAsleep.map { HealthFormat.time($0, calendar: calendar) }),
            "wokeUp": .str(wokeUp.map { HealthFormat.time($0, calendar: calendar) }),
            "deepMinutes": HealthFormat.rounded(deepSeconds > 0 ? deepSeconds / 60 : nil, 0),
            "remMinutes": HealthFormat.rounded(remSeconds > 0 ? remSeconds / 60 : nil, 0),
            "coreMinutes": HealthFormat.rounded(coreSeconds > 0 ? coreSeconds / 60 : nil, 0),
            "awakeMinutes": HealthFormat.rounded(awakeSeconds > 0 ? awakeSeconds / 60 : nil, 0),
            "inBedMinutes": HealthFormat.rounded(inBedSeconds > 0 ? inBedSeconds / 60 : nil, 0),
        ])
    }
}

/// Builds the nights out of the sleep samples: Santé keeps one sample per stage and per source, so a night arrives
/// as dozens of overlapping pieces that have to be merged before anything is counted.
enum HealthSleep {
    /// A night runs from noon to noon: everything one sleeps before midday counts for that morning.
    static func night(of date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: date)
        let day = calendar.startOfDay(for: date)
        return hour < 12 ? day : calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    static func nights(from pieces: [SleepPiece], calendar: Calendar = .current) -> [SleepNight] {
        let usable = pieces.filter { $0.seconds > 0 }
        let grouped = Dictionary(grouping: usable) { night(of: $0.start, calendar: calendar) }
        return grouped.keys.sorted().map { day in
            let night = grouped[day] ?? []
            let asleep = night.filter { $0.stage != .awake && $0.stage != .inBed }
            let merged = union(asleep)
            var out = SleepNight(
                date: day,
                fellAsleep: merged.first?.lowerBound,
                wokeUp: merged.last?.upperBound,
                asleepSeconds: seconds(merged),
                deepSeconds: seconds(union(night.filter { $0.stage == .deep })),
                remSeconds: seconds(union(night.filter { $0.stage == .rem })),
                coreSeconds: seconds(union(night.filter { $0.stage == .core })),
                awakeSeconds: seconds(union(night.filter { $0.stage == .awake })),
                inBedSeconds: seconds(union(night.filter { $0.stage == .inBed }))
            )
            // A source that only says « asleep » gives no phases: the total still holds.
            if out.deepSeconds + out.remSeconds + out.coreSeconds > out.asleepSeconds { out.asleepSeconds = out.deepSeconds + out.remSeconds + out.coreSeconds }
            return out
        }
    }

    /// The stretches of time covered by the pieces, overlaps counted once.
    static func union(_ pieces: [SleepPiece]) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, piece.start <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, piece.end)
            } else {
                out.append(piece.start...piece.end)
            }
        }
        return out
    }

    private static func seconds(_ ranges: [ClosedRange<Date>]) -> Double {
        ranges.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
    }
}

/// A session Santé recorded: a run, a ride, a swim, a session of anything.
struct WorkoutSummary: Equatable, Sendable {
    let id: String
    let activity: String
    let start: Date
    let end: Date
    var distanceMeters: Double?
    var activeEnergy: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var elevationMeters: Double?
    var indoor: Bool?
    var source: String?

    var seconds: Double { max(0, end.timeIntervalSince(start)) }

    func json(calendar: Calendar = .current) -> JSONValue {
        .fields([
            "id": .string(id),
            "activity": .string(activity),
            "start": .string(HealthFormat.time(start, calendar: calendar)),
            "duration": .str(HealthFormat.duration(seconds: seconds)),
            "durationMinutes": HealthFormat.rounded(seconds / 60, 0),
            "distanceKm": HealthFormat.rounded(distanceMeters.map { $0 / 1000 }, 2),
            "pace": .str(distanceMeters.flatMap { HealthFormat.pace(meters: $0, seconds: seconds) }),
            "activeEnergyKcal": HealthFormat.rounded(activeEnergy, 0),
            "averageBpm": HealthFormat.rounded(averageHeartRate, 0),
            "maxBpm": HealthFormat.rounded(maxHeartRate, 0),
            "elevationGainM": HealthFormat.rounded(elevationMeters, 0),
            "indoor": indoor == true ? .bool(true) : nil,
            "source": .str(source),
        ])
    }
}

/// The measurements, each one as of its own last reading.
struct BodySnapshot: Equatable, Sendable {
    var weightKg: (value: Double, date: Date)?
    var heightCm: (value: Double, date: Date)?
    var bodyFatPercent: (value: Double, date: Date)?
    var leanMassKg: (value: Double, date: Date)?
    var vo2Max: (value: Double, date: Date)?
    /// Weight at the start of the period, to say which way it went.
    var weightEarlierKg: Double?

    static func == (a: BodySnapshot, b: BodySnapshot) -> Bool { a.json() == b.json() }

    func json(calendar: Calendar = .current) -> JSONValue {
        let measure = { (m: (value: Double, date: Date)?, places: Int) -> JSONValue? in
            guard let m else { return nil }
            return .fields(["value": .rounded(m.value, places), "day": .string(HealthFormat.day(m.date, calendar: calendar))])
        }
        let bmi: JSONValue? = {
            guard let weight = weightKg?.value, let height = heightCm?.value, height > 0 else { return nil }
            return .rounded(weight / pow(height / 100, 2), 1)
        }()
        return .fields([
            "weightKg": measure(weightKg, 2),
            "weightChangeKg": HealthFormat.rounded(weightKg.flatMap { w in weightEarlierKg.map { w.value - $0 } }, 2),
            "heightCm": measure(heightCm, 0),
            "bmi": bmi,
            "bodyFatPercent": measure(bodyFatPercent, 1),
            "leanMassKg": measure(leanMassKg, 1),
            "vo2Max": measure(vo2Max, 1),
        ])
    }
}

/// The tools' answers: days, nights and sessions, with the totals a bot would otherwise compute itself.
enum HealthReport {
    static func period(_ window: HealthWindow, calendar: Calendar = .current) -> KeyValuePairs<String, JSONValue?> {
        [
            "from": .string(HealthFormat.day(window.start, calendar: calendar)),
            "to": .string(HealthFormat.day(calendar.date(byAdding: .day, value: -1, to: window.end) ?? window.start, calendar: calendar)),
            "days": .number(Double(window.days)),
        ]
    }

    static func activity(_ days: [ActivityDay], window: HealthWindow, calendar: Calendar = .current) -> JSONValue {
        var out = object(period(window, calendar: calendar))
        out["days"] = .number(Double(window.days))
        out["averages"] = .fields([
            "steps": HealthFormat.rounded(HealthFormat.mean(days.map(\.steps)), 0),
            "distanceKm": HealthFormat.rounded(HealthFormat.mean(days.map { $0.distanceMeters.map { $0 / 1000 } }), 2),
            "activeEnergyKcal": HealthFormat.rounded(HealthFormat.mean(days.map(\.activeEnergy)), 0),
            "exerciseMinutes": HealthFormat.rounded(HealthFormat.mean(days.map(\.exerciseMinutes)), 0),
        ])
        out["totals"] = .fields([
            "steps": HealthFormat.rounded(HealthFormat.total(days.map(\.steps)), 0),
            "distanceKm": HealthFormat.rounded(HealthFormat.total(days.map { $0.distanceMeters.map { $0 / 1000 } }), 1),
            "activeEnergyKcal": HealthFormat.rounded(HealthFormat.total(days.map(\.activeEnergy)), 0),
            "exerciseMinutes": HealthFormat.rounded(HealthFormat.total(days.map(\.exerciseMinutes)), 0),
        ])
        out["activity"] = .array(days.map { $0.json(calendar: calendar) })
        return .object(out)
    }

    static func heart(_ days: [HeartDay], vo2Max: Double?, window: HealthWindow, calendar: Calendar = .current) -> JSONValue {
        var out = object(period(window, calendar: calendar))
        out["averages"] = .fields([
            "restingBpm": HealthFormat.rounded(HealthFormat.mean(days.map(\.restingHeartRate)), 0),
            "hrvMs": HealthFormat.rounded(HealthFormat.mean(days.map(\.heartRateVariability)), 0),
            "walkingBpm": HealthFormat.rounded(HealthFormat.mean(days.map(\.walkingHeartRate)), 0),
        ])
        if let vo2Max { out["vo2Max"] = .rounded(vo2Max, 1) }
        out["heart"] = .array(days.map { $0.json(calendar: calendar) })
        return .object(out)
    }

    static func sleep(_ nights: [SleepNight], window: HealthWindow, calendar: Calendar = .current) -> JSONValue {
        var out = object(period(window, calendar: calendar))
        let average = HealthFormat.mean(nights.map { $0.asleepSeconds })
        out["averageAsleep"] = .str(average.flatMap { HealthFormat.duration(seconds: $0) })
        out["averageAsleepMinutes"] = HealthFormat.rounded(average.map { $0 / 60 }, 0)
        out["nights"] = .array(nights.map { $0.json(calendar: calendar) })
        return .object(out)
    }

    static func workouts(_ workouts: [WorkoutSummary], window: HealthWindow, truncated: Bool = false, calendar: Calendar = .current) -> JSONValue {
        var out = object(period(window, calendar: calendar))
        out["count"] = .number(Double(workouts.count))
        if truncated { out["truncated"] = .bool(true) }
        out["totals"] = .fields([
            "minutes": HealthFormat.rounded(HealthFormat.total(workouts.map { $0.seconds / 60 }), 0),
            "distanceKm": HealthFormat.rounded(HealthFormat.total(workouts.map { $0.distanceMeters.map { $0 / 1000 } }), 1),
            "activeEnergyKcal": HealthFormat.rounded(HealthFormat.total(workouts.map(\.activeEnergy)), 0),
        ])
        out["workouts"] = .array(workouts.map { $0.json(calendar: calendar) })
        return .object(out)
    }

    /// The one-call overview: today and the days behind it, last night, the heart, the latest sessions.
    static func summary(activity: [ActivityDay], heart: [HeartDay], nights: [SleepNight], workouts: [WorkoutSummary],
                        body: BodySnapshot, window: HealthWindow, calendar: Calendar = .current) -> JSONValue {
        var out = object(period(window, calendar: calendar))
        let today = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: window.end) ?? window.start)
        out["today"] = (activity.first { calendar.isDate($0.date, inSameDayAs: today) } ?? activity.last)?.json(calendar: calendar)
        out["activityAverages"] = .fields([
            "steps": HealthFormat.rounded(HealthFormat.mean(activity.map(\.steps)), 0),
            "distanceKm": HealthFormat.rounded(HealthFormat.mean(activity.map { $0.distanceMeters.map { $0 / 1000 } }), 2),
            "activeEnergyKcal": HealthFormat.rounded(HealthFormat.mean(activity.map(\.activeEnergy)), 0),
            "exerciseMinutes": HealthFormat.rounded(HealthFormat.mean(activity.map(\.exerciseMinutes)), 0),
        ])
        out["lastNight"] = nights.last?.json(calendar: calendar)
        out["sleepAverageMinutes"] = HealthFormat.rounded(HealthFormat.mean(nights.map { $0.asleepSeconds / 60 }), 0)
        out["heartAverages"] = .fields([
            "restingBpm": HealthFormat.rounded(HealthFormat.mean(heart.map(\.restingHeartRate)), 0),
            "hrvMs": HealthFormat.rounded(HealthFormat.mean(heart.map(\.heartRateVariability)), 0),
        ])
        out["lastHeartDay"] = heart.last?.json(calendar: calendar)
        out["body"] = body.json(calendar: calendar)
        out["workoutCount"] = .number(Double(workouts.count))
        out["lastWorkouts"] = .array(workouts.suffix(5).reversed().map { $0.json(calendar: calendar) })
        return .object(out)
    }

    private static func object(_ fields: KeyValuePairs<String, JSONValue?>) -> [String: JSONValue] {
        guard case let .object(o) = JSONValue.fields(fields) else { return [:] }
        return o
    }
}
