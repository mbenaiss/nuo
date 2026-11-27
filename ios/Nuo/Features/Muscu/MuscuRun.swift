import Foundation

// MARK: - Gateway payloads (`GET /api/muscu`, `POST /api/muscu/sessions`)

struct MuscuExercise: Codable, Hashable, Sendable {
    var name: String
    var reps: Int
    /// Replacements when the machine is taken, the suggested one first.
    var alts: [String]
}

struct MuscuBlock: Codable, Hashable, Sendable {
    var exercises: [MuscuExercise]
    var note: String?
}

/// A gym session the Coach saved: every block for `sets` sets, in any order.
struct MuscuSession: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
    var note: String
    var blocks: [MuscuBlock]
    var sets: Int
    /// Rest between two sets of a block (s).
    var rest: Int
    /// Rest when moving to another block (s).
    var restBlock: Int
    var rir: Int?
    /// ISO weekdays (1 = Monday) the session is planned on.
    var days: [Int]
}

struct MuscuLastLoad: Codable, Hashable, Sendable {
    var kg: Double?
    var reps: Int
    var day: String
}

struct MuscuCatalog: Codable, Hashable, Sendable {
    var sessions: [MuscuSession]
    /// Gateway path of the machine photo of each exercise and replacement.
    var photos: [String: String]
    var loads: [String: MuscuLastLoad]
}

struct MuscuFinishedBody: Codable, Equatable, Sendable {
    struct Exercise: Codable, Equatable, Sendable {
        var name: String
        var base: String
        var reps: Int
        var kg: Double?
    }

    struct DoneSet: Codable, Equatable, Sendable {
        var block: Int
        var exercises: [Exercise]
    }

    var runId: String
    var sessionId: Int
    var day: String
    var seconds: Int
    var sets: [DoneSet]
}

struct MuscuLogged: Codable, Sendable {
    var workoutId: Int
    var title: String
    var detail: String
}

// MARK: - A run of a session

/// One session as it is being done, saved after every action so a relaunch resumes it. Blocks are done in any order:
/// `current` is the block on screen, the real order comes from the log. Mirrors the chrono's `session.js`.
struct MuscuRun: Codable, Equatable, Sendable {
    static let version = 1
    /// A run left open this long is a forgotten session, not one to resume.
    static let maxAge: TimeInterval = 4 * 3600

    struct Value: Codable, Equatable, Sendable {
        var reps: Int
        var kg: Double?
    }

    struct LoggedSet: Codable, Equatable, Sendable {
        var block: Int
        var at: Date
        var exercises: [MuscuFinishedBody.Exercise]
    }

    enum RestKind: String, Codable, Sendable { case set, block }

    struct Rest: Codable, Equatable, Sendable {
        var until: Date
        var total: Int
        var kind: RestKind
    }

    var v = MuscuRun.version
    /// Sent with the finished session: sending it again rewrites the same workout.
    var id: String
    var sessionId: Int
    var blockCount: Int
    var startedAt: Date
    var endedAt: Date?
    var current = 0
    var done: [Int]
    var skipped: [Int]
    /// Replacement of an exercise, by `exerciseKey`.
    var swaps: [String: String] = [:]
    var values: [String: Value] = [:]
    var log: [LoggedSet] = []
    var rest: Rest?
    /// The gateway logged it for the Coach.
    var uploaded = false

    static func exerciseKey(_ block: Int, _ exercise: Int) -> String { "\(block).\(exercise)" }

    init(session: MuscuSession, loads: MuscuLoads, now: Date, id: String = UUID().uuidString) {
        self.id = id
        sessionId = session.id
        blockCount = session.blocks.count
        startedAt = now
        done = Array(repeating: 0, count: session.blocks.count)
        skipped = Array(repeating: 0, count: session.blocks.count)
        for (bi, block) in session.blocks.enumerated() {
            for (ei, exercise) in block.exercises.enumerated() {
                values[Self.exerciseKey(bi, ei)] = Value(reps: exercise.reps, kg: loads.kg(for: exercise.name))
            }
        }
    }

    var isFinished: Bool { endedAt != nil }

    /// An exercise of a block as it stands in this run: replacement applied, current reps and load.
    struct LiveExercise: Equatable, Identifiable, Sendable {
        var key: String
        var index: Int
        var base: MuscuExercise
        var name: String
        var reps: Int
        var kg: Double?
        /// Once swapped, the original machine is the first way back.
        var alts: [String]
        var id: String { key }
        var swapped: Bool { name != base.name }
    }

    func exercises(of block: Int, in session: MuscuSession) -> [LiveExercise] {
        session.blocks[block].exercises.enumerated().map { ei, base in
            let key = Self.exerciseKey(block, ei)
            let name = swaps[key] ?? base.name
            let value = values[key] ?? Value(reps: base.reps, kg: nil)
            let alts = name != base.name ? [base.name] + base.alts.filter { $0 != name } : base.alts
            return LiveExercise(key: key, index: ei, base: base, name: name, reps: value.reps, kg: value.kg, alts: alts)
        }
    }

    func setsLeft(_ block: Int, in session: MuscuSession) -> Int { session.sets - done[block] - skipped[block] }
    func isFinished(block: Int, in session: MuscuSession) -> Bool { setsLeft(block, in: session) <= 0 }
    /// 1-based number of the set on screen in its block.
    func setNumber(_ block: Int) -> Int { done[block] + skipped[block] + 1 }
    var setsDone: Int { done.reduce(0, +) }

    /// Blocks still to do besides the one on screen, in the planned order.
    func remainingBlocks(in session: MuscuSession) -> [Int] {
        (0..<session.blocks.count).filter { $0 != current && !isFinished(block: $0, in: session) }
    }

    /// Blocks in the order they were really done (first set logged).
    var realOrder: [Int] {
        var seen: [Int] = []
        for entry in log where !seen.contains(entry.block) { seen.append(entry.block) }
        return seen
    }

    func restLeft(at now: Date) -> TimeInterval {
        guard let rest else { return 0 }
        return max(0, rest.until.timeIntervalSince(now))
    }

    // MARK: Actions

    /// Logs the set on screen with its reps and loads, remembers the loads for next time, starts the rest.
    mutating func completeSet(in session: MuscuSession, loads: inout MuscuLoads, now: Date) {
        let block = current
        let lifted = exercises(of: block, in: session).map {
            MuscuFinishedBody.Exercise(name: $0.name, base: $0.base.name, reps: $0.reps, kg: $0.kg)
        }
        log.append(LoggedSet(block: block, at: now, exercises: lifted))
        done[block] += 1
        for exercise in lifted {
            if let kg = exercise.kg { loads.remember(exercise.name, kg: kg) }
        }
        advance(in: session, now: now, rest: true)
    }

    /// "Skip": the set on screen is dropped, not logged, and the next one starts without rest.
    mutating func skipSet(in session: MuscuSession, now: Date) {
        skipped[current] += 1
        rest = nil
        advance(in: session, now: now, rest: false)
    }

    /// Another block now; the one left keeps its sets and stays in the remaining blocks.
    mutating func switchBlock(to block: Int) {
        guard block >= 0, block < blockCount else { return }
        current = block
        rest = nil
    }

    /// Replaces one exercise of a block for the rest of the session; its own last load is prefilled.
    mutating func replaceExercise(block: Int, exercise: Int, with name: String, in session: MuscuSession, loads: MuscuLoads) {
        let key = Self.exerciseKey(block, exercise)
        let base = session.blocks[block].exercises[exercise]
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if clean == base.name { swaps[key] = nil } else { swaps[key] = clean }
        values[key] = Value(reps: values[key]?.reps ?? base.reps, kg: loads.kg(for: clean))
    }

    mutating func setReps(_ reps: Int, key: String) {
        values[key]?.reps = min(100, max(1, reps))
    }

    mutating func setKg(_ kg: Double?, key: String) {
        values[key]?.kg = kg.map { min(500, max(0, ($0 * 100).rounded() / 100)) }
    }

    mutating func addRest(seconds: Int) {
        guard var rest else { return }
        rest.until.addTimeInterval(TimeInterval(seconds))
        rest.total += seconds
        self.rest = rest
    }

    mutating func endRest() { rest = nil }

    mutating func finish(now: Date) {
        endedAt = now
        rest = nil
    }

    /// After a set: rest before the next set of the block, or move on to the next block (longer rest).
    private mutating func advance(in session: MuscuSession, now: Date, rest withRest: Bool) {
        if !isFinished(block: current, in: session) {
            if withRest { rest = Rest(until: now.addingTimeInterval(TimeInterval(session.rest)), total: session.rest, kind: .set) }
            return
        }
        guard let next = remainingBlocks(in: session).first else {
            finish(now: now)
            return
        }
        current = next
        if withRest { rest = Rest(until: now.addingTimeInterval(TimeInterval(session.restBlock)), total: session.restBlock, kind: .block) }
    }

    // MARK: Restore and send

    /// The saved run if it still belongs to a known session and is not a forgotten one.
    static func restore(_ data: Data?, sessions: [MuscuSession], now: Date) -> MuscuRun? {
        guard let data, var run = try? JSONDecoder().decode(MuscuRun.self, from: data), run.v == version else { return nil }
        guard let session = sessions.first(where: { $0.id == run.sessionId }), session.blocks.count == run.blockCount else { return nil }
        if run.endedAt == nil, now.timeIntervalSince(run.startedAt) > maxAge { return nil }
        // A rest that ran out while the app was closed is over.
        if let rest = run.rest, rest.until <= now { run.rest = nil }
        return run
    }

    func finishedBody(calendar: Calendar = .current) -> MuscuFinishedBody {
        let day = calendar.dateComponents([.year, .month, .day], from: startedAt)
        let end = endedAt ?? startedAt
        return MuscuFinishedBody(
            runId: id,
            sessionId: sessionId,
            day: String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0),
            seconds: max(0, Int(end.timeIntervalSince(startedAt).rounded())),
            sets: log.map { MuscuFinishedBody.DoneSet(block: $0.block, exercises: $0.exercises) })
    }

    /// "Block B · set 2/3".
    func stepLabel(in session: MuscuSession) -> String {
        String(localized: "Block \(MuscuFormat.letter(current)) · set \(min(setNumber(current), session.sets))/\(session.sets)")
    }
}

// MARK: - Session choice and last loads

enum MuscuPlan {
    /// ISO weekday, 1 = Monday.
    static func isoWeekday(_ date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// The session planned on this weekday, else the one picked last time, else the newest.
    static func pick(_ sessions: [MuscuSession], date: Date, lastId: Int?, calendar: Calendar = .current) -> MuscuSession? {
        let day = isoWeekday(date, calendar: calendar)
        return sessions.first { $0.days.contains(day) } ?? sessions.first { $0.id == lastId } ?? sessions.first
    }

    static func isPlanned(_ session: MuscuSession, on date: Date, calendar: Calendar = .current) -> Bool {
        session.days.contains(isoWeekday(date, calendar: calendar))
    }
}

/// Last load per exercise, by folded name: the gateway's (sessions logged) under the ones lifted on this iPhone.
struct MuscuLoads: Codable, Equatable, Sendable {
    private(set) var kgs: [String: Double] = [:]

    init(gateway: [String: MuscuLastLoad] = [:], local: MuscuLoads? = nil) {
        for (name, load) in gateway { if let kg = load.kg { kgs[Self.fold(name)] = kg } }
        if let local { kgs.merge(local.kgs) { _, mine in mine } }
    }

    static func fold(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func kg(for name: String) -> Double? { kgs[Self.fold(name)] }
    mutating func remember(_ name: String, kg: Double) { kgs[Self.fold(name)] = kg }
}

enum MuscuFormat {
    static func letter(_ block: Int) -> String { String(Character(UnicodeScalar(UInt8(65 + max(0, min(block, 25)))))) }

    /// 42.5 (42,5 in French); 40.
    static func kg(_ kg: Double, locale: Locale = .current) -> String {
        let rounded = (kg * 100).rounded() / 100
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    /// 1:15, 2:00.
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let rest = String(format: "%02d", s % 60)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(rest)" : "\(m):\(rest)"
    }

    /// "4 blocks × 3 sets · rest 1:15 / 2:00 · 2 reps in reserve".
    static func summary(_ session: MuscuSession) -> String {
        let blocks = String(localized: "\(session.blocks.count) blocks")
        let sets = String(localized: "\(session.sets) sets")
        var parts = ["\(blocks) × \(sets)",
                     String(localized: "rest \(clock(session.rest)) / \(clock(session.restBlock))")]
        if let rir = session.rir { parts.append(String(localized: "\(rir) reps in reserve")) }
        return parts.joined(separator: " · ")
    }
}
