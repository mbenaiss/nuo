import Foundation

/// What a step asks the watch to do until it ends.
enum WorkoutStepGoal: Equatable, Sendable {
    case distance(meters: Double)
    case time(seconds: Double)
    /// Until the wrist is tapped.
    case open

    var label: String {
        switch self {
        case let .distance(meters): meters >= 1000 ? "\(Self.km(meters)) km" : "\(Int(meters.rounded())) m"
        case let .time(seconds): HealthFormat.duration(seconds: seconds) ?? "\(Int(seconds)) s"
        case .open: "libre"
        }
    }

    private static func km(_ meters: Double) -> String {
        let value = (meters / 100).rounded() / 10
        return value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// The pace or heart rate the watch keeps the runner on during a step.
enum WorkoutStepTarget: Equatable, Sendable {
    /// Seconds per kilometre; `fast` is the quicker end of the range (fewer seconds).
    case paceRange(fast: Double, slow: Double)
    case pace(secondsPerKm: Double)
    case heartRateZone(Int)
    case heartRateRange(low: Double, high: Double)
    case heartRateCeiling(Double)

    var label: String {
        switch self {
        case let .paceRange(fast, slow): "\(HealthFormat.pace(secondsPerKm: fast) ?? "") à \(HealthFormat.pace(secondsPerKm: slow) ?? "")"
        case let .pace(seconds): HealthFormat.pace(secondsPerKm: seconds) ?? ""
        case let .heartRateZone(zone): "zone \(zone)"
        case let .heartRateRange(low, high): "\(Int(low))–\(Int(high)) bpm"
        case let .heartRateCeiling(max): "sous \(Int(max)) bpm"
        }
    }
}

struct WorkoutDraftStep: Equatable, Sendable {
    enum Purpose: String, Sendable { case work, recovery }

    var purpose: Purpose = .work
    var goal: WorkoutStepGoal
    var target: WorkoutStepTarget?
    var name: String?

    var label: String {
        let pieces = [name, goal.label, target?.label].compactMap { $0?.isEmpty == false ? $0 : nil }
        return pieces.joined(separator: " · ")
    }
}

struct WorkoutDraftBlock: Equatable, Sendable {
    var steps: [WorkoutDraftStep]
    var iterations: Int = 1

    var label: String {
        let body = steps.map(\.label).joined(separator: " puis ")
        return iterations > 1 ? "\(iterations) × (\(body))" : body
    }
}

/// A structured session a bot composed, checked before WorkoutKit ever sees it: the framework traps on a bad range
/// or an empty plan instead of throwing, so everything is refused here with a message the bot can act on.
struct WorkoutPlanDraft: Equatable, Sendable {
    enum Sport: String, Sendable, CaseIterable {
        case running, cycling, walking, swimming, rowing, elliptical

        var french: String {
            switch self {
            case .running: "course"
            case .cycling: "vélo"
            case .walking: "marche"
            case .swimming: "natation"
            case .rowing: "rameur"
            case .elliptical: "elliptique"
            }
        }
    }

    enum Place: String, Sendable { case outdoor, indoor }

    /// WorkoutKit refuses a plan past this many steps.
    static let maxSteps = 50

    var name: String
    var sport: Sport
    var place: Place
    var warmup: WorkoutDraftStep?
    var blocks: [WorkoutDraftBlock]
    var cooldown: WorkoutDraftStep?
    /// When it should show up in Fitness and on the watch; nil means now.
    var date: Date?

    var stepCount: Int {
        (warmup == nil ? 0 : 1) + blocks.reduce(0) { $0 + $1.steps.count * max($1.iterations, 1) } + (cooldown == nil ? 0 : 1)
    }

    /// What the bot tells the user it put on the watch.
    var summary: String {
        var lines: [String] = []
        if let warmup { lines.append("échauffement : \(warmup.label)") }
        lines.append(contentsOf: blocks.map(\.label))
        if let cooldown { lines.append("retour au calme : \(cooldown.label)") }
        return lines.joined(separator: " / ")
    }

    /// Minutes of work the session adds up to, for the steps that have a duration or a pace to run a distance at.
    var estimatedSeconds: Double? {
        var total: Double = 0
        var known = false
        for step in [warmup, cooldown].compactMap({ $0 }) + blocks.flatMap({ b in b.steps.flatMap { s in Array(repeating: s, count: max(b.iterations, 1)) } }) {
            switch step.goal {
            case let .time(seconds):
                total += seconds
                known = true
            case let .distance(meters):
                guard let pace = step.target?.secondsPerKm else { continue }
                total += (meters / 1000) * pace
                known = true
            case .open:
                continue
            }
        }
        return known ? total : nil
    }

    func json() -> JSONValue {
        .fields([
            "name": .string(name),
            "sport": .string(sport.rawValue),
            "location": .string(place.rawValue),
            "steps": .number(Double(stepCount)),
            "date": .str(date.map { HealthFormat.time($0) }),
            "estimatedMinutes": HealthFormat.rounded(estimatedSeconds.map { $0 / 60 }, 0),
            "plan": .string(summary),
        ])
    }
}

extension WorkoutStepTarget {
    var secondsPerKm: Double? {
        switch self {
        case let .pace(seconds): seconds
        case let .paceRange(fast, slow): (fast + slow) / 2
        default: nil
        }
    }
}

/// Reads a session as a bot writes it (`workout_schedule`).
enum WorkoutDraftParser {
    static let maxBlocks = 20
    static let maxStepsPerBlock = 10

    static func parse(_ args: DeviceToolArgs, now: Date = Date(), calendar: Calendar = .current) throws -> WorkoutPlanDraft {
        guard let name = args.string("name") else { throw DeviceToolError("name requis : le nom de la séance, tel qu'il s'affichera sur la montre.") }
        let sportText = args.string("sport")?.lowercased() ?? "running"
        guard let sport = WorkoutPlanDraft.Sport(rawValue: sportText) else {
            throw DeviceToolError("Sport inconnu « \(sportText) » : \(WorkoutPlanDraft.Sport.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let placeText = args.string("location")?.lowercased() ?? "outdoor"
        guard let place = WorkoutPlanDraft.Place(rawValue: placeText) else { throw DeviceToolError("location inconnu « \(placeText) » : outdoor ou indoor.") }

        let blocks = try self.blocks(args)
        let warmup = try args.object("warmup").map { try step($0, purpose: .work, what: "warmup") }
        let cooldown = try args.object("cooldown").map { try step($0, purpose: .work, what: "cooldown") }
        guard !blocks.isEmpty || warmup != nil || cooldown != nil else {
            throw DeviceToolError("Séance vide : donne au moins un bloc dans blocks, ou un warmup ou un cooldown.")
        }
        var draft = WorkoutPlanDraft(name: name, sport: sport, place: place, warmup: warmup, blocks: blocks, cooldown: cooldown, date: try date(args, now: now, calendar: calendar))
        guard draft.stepCount <= WorkoutPlanDraft.maxSteps else {
            throw DeviceToolError("Séance trop longue : \(draft.stepCount) étapes alors que la montre en accepte \(WorkoutPlanDraft.maxSteps). Regroupe les répétitions dans un bloc avec repeat.")
        }
        if draft.name.count > 60 { draft.name = String(draft.name.prefix(60)) }
        return draft
    }

    /// A workout scheduled in the past never shows up: the bot's date is kept as given, and « now » stands in for it.
    static func date(_ args: DeviceToolArgs, now: Date = Date(), calendar: Calendar = .current) throws -> Date? {
        guard let parsed = try DeviceToolDate.require(args, "date") else { return nil }
        // A bare day means the morning of that day, not midnight gone by.
        let at = parsed.dayOnly ? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: parsed.date) ?? parsed.date : parsed.date
        return max(at, now)
    }

    private static func blocks(_ args: DeviceToolArgs) throws -> [WorkoutDraftBlock] {
        guard case let .array(raw) = args.raw["blocks"] else {
            if args.has("blocks") { throw DeviceToolError("blocks doit être une liste de blocs { repeat, steps }.") }
            return []
        }
        guard raw.count <= maxBlocks else { throw DeviceToolError("\(raw.count) blocs : \(maxBlocks) au maximum.") }
        return try raw.enumerated().map { index, item in
            guard case let .object(o) = item else { throw DeviceToolError("blocs[\(index)] doit être un objet { repeat, steps }.") }
            let block = DeviceToolArgs(o)
            let iterations = block.int("repeat", default: 1, range: 1...50)
            guard case let .array(rawSteps) = block.raw["steps"] else { throw DeviceToolError("blocs[\(index)] : steps requis (liste d'étapes).") }
            guard !rawSteps.isEmpty else { throw DeviceToolError("blocs[\(index)] : steps est vide.") }
            guard rawSteps.count <= maxStepsPerBlock else { throw DeviceToolError("blocs[\(index)] : \(rawSteps.count) étapes, \(maxStepsPerBlock) au maximum.") }
            let steps = try rawSteps.enumerated().map { stepIndex, rawStep -> WorkoutDraftStep in
                guard case let .object(so) = rawStep else { throw DeviceToolError("blocs[\(index)].steps[\(stepIndex)] doit être un objet.") }
                let purposeText = DeviceToolArgs(so).string("purpose")?.lowercased() ?? "work"
                guard let purpose = WorkoutDraftStep.Purpose(rawValue: purposeText) else {
                    throw DeviceToolError("blocs[\(index)].steps[\(stepIndex)] : purpose inconnu « \(purposeText) » (work ou recovery).")
                }
                return try step(DeviceToolArgs(so), purpose: purpose, what: "blocs[\(index)].steps[\(stepIndex)]")
            }
            return WorkoutDraftBlock(steps: steps, iterations: iterations)
        }
    }

    static func step(_ args: DeviceToolArgs, purpose: WorkoutDraftStep.Purpose, what: String) throws -> WorkoutDraftStep {
        WorkoutDraftStep(purpose: purpose, goal: try goal(args, what: what), target: try target(args, what: what), name: args.string("name"))
    }

    static func goal(_ args: DeviceToolArgs, what: String) throws -> WorkoutStepGoal {
        if let km = args.number("km") {
            guard km > 0, km <= 300 else { throw DeviceToolError("\(what) : km doit être entre 0 et 300.") }
            return .distance(meters: km * 1000)
        }
        if let meters = args.number("distance") {
            guard meters > 0, meters <= 300_000 else { throw DeviceToolError("\(what) : distance (en mètres) doit être entre 0 et 300000.") }
            return .distance(meters: meters)
        }
        if let minutes = args.number("minutes") {
            guard minutes > 0, minutes <= 600 else { throw DeviceToolError("\(what) : minutes doit être entre 0 et 600.") }
            return .time(seconds: minutes * 60)
        }
        if let seconds = args.number("duration") {
            guard seconds > 0, seconds <= 36_000 else { throw DeviceToolError("\(what) : duration (en secondes) doit être entre 0 et 36000.") }
            return .time(seconds: seconds)
        }
        if args.bool("open") == true { return .open }
        throw DeviceToolError("\(what) : donne une fin à l'étape — km ou distance (mètres), minutes ou duration (secondes), ou open: true.")
    }

    static func target(_ args: DeviceToolArgs, what: String) throws -> WorkoutStepTarget? {
        let fast = try args.string("pace_fast").map { try pace($0, what: what) }
        let slow = try args.string("pace_slow").map { try pace($0, what: what) }
        if let fast, let slow {
            // WorkoutKit traps unless the bounds differ: the same pace twice is a single target.
            return fast == slow ? .pace(secondsPerKm: fast) : .paceRange(fast: min(fast, slow), slow: max(fast, slow))
        }
        if let only = fast ?? slow { return .pace(secondsPerKm: only) }
        if let text = args.string("pace") { return .pace(secondsPerKm: try pace(text, what: what)) }
        if let zone = args.number("heart_rate_zone") {
            guard zone >= 1, zone <= 5 else { throw DeviceToolError("\(what) : heart_rate_zone va de 1 à 5.") }
            return .heartRateZone(Int(zone))
        }
        let low = args.number("heart_rate_min")
        let high = args.number("heart_rate_max")
        if let low, let high {
            guard low >= 30, high > low, high <= 240 else { throw DeviceToolError("\(what) : heart_rate_min et heart_rate_max doivent aller de 30 à 240, min sous max.") }
            return .heartRateRange(low: low, high: high)
        }
        if let high {
            guard high > 30, high <= 240 else { throw DeviceToolError("\(what) : heart_rate_max doit aller de 30 à 240.") }
            return .heartRateCeiling(high)
        }
        if let low {
            guard low >= 30, low < 240 else { throw DeviceToolError("\(what) : heart_rate_min doit aller de 30 à 240.") }
            return .heartRateRange(low: low, high: 240)
        }
        return nil
    }

    /// « 4:30 », « 4:30/km » or a number of seconds per kilometre.
    static func pace(_ text: String, what: String) throws -> Double {
        let clean = text.replacingOccurrences(of: "/km", with: "").trimmingCharacters(in: .whitespaces)
        let seconds: Double?
        if clean.contains(":") {
            let parts = clean.split(separator: ":")
            seconds = parts.count == 2 ? (Double(parts[0]).flatMap { m in Double(parts[1]).map { m * 60 + $0 } }) : nil
        } else {
            seconds = Double(clean.replacingOccurrences(of: ",", with: "."))
        }
        guard let seconds, seconds >= 120, seconds <= 1800 else {
            throw DeviceToolError("\(what) : allure invalide « \(text) » — écris-la « 4:30 » (min:s par kilomètre), entre 2:00 et 30:00.")
        }
        return seconds
    }
}
