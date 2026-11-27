#if os(iOS)
import Foundation
import HealthKit
@preconcurrency import WorkoutKit

/// The `workout_*` tools: a bot composes a structured session and the iPhone hands it to WorkoutKit, which puts it in
/// the Fitness app and on the paired Apple Watch, in its own Exercice app (docs/health.md). Nothing leaves the iPhone.
final class AppleWorkoutTools: Sendable {
    /// The iPhone's name, as the refusals a bot reads name it; read once, on the main actor.
    private let device: String

    init(device: String) { self.device = device }

    func perform(_ tool: String, _ args: DeviceToolArgs) async throws -> JSONValue {
        guard WorkoutScheduler.isSupported else { throw DeviceToolError("WorkoutKit n'est pas disponible sur \(device).") }
        switch tool {
        case "workout_schedule": return try await schedule(args)
        case "workout_scheduled": return try await scheduled()
        case "workout_cancel": return try await cancel(args)
        default: throw DeviceToolError("Outil inconnu \(tool).")
        }
    }

    static var isSupported: Bool { WorkoutScheduler.isSupported }

    /// `AuthorizationState` is not Sendable: it is read and compared away from any actor, and only the answer travels.
    static func isAllowed() async -> Bool {
        await WorkoutScheduler.shared.authorizationState == .authorized
    }

    static func requestAccess() async -> Bool {
        await WorkoutScheduler.shared.requestAuthorization() == .authorized
    }

    private func authorize() async throws {
        guard await Self.requestAccess() else {
            throw DeviceToolError("L'utilisateur n'a pas autorisé Nuo à programmer des séances sur \(device) : il peut l'autoriser dans Nuo, Réglages › Accès des bots.")
        }
    }

    private func schedule(_ args: DeviceToolArgs) async throws -> JSONValue {
        let draft = try WorkoutDraftParser.parse(args)
        try await authorize()
        let plan = WorkoutPlan(.custom(try Self.custom(draft)))
        let at = Self.dateComponents(draft.date ?? Date())
        let before = await WorkoutScheduler.shared.scheduledWorkouts.count
        guard before < WorkoutScheduler.maxAllowedScheduledWorkoutCount else {
            throw DeviceToolError("\(before) séances déjà programmées, soit le maximum : annules-en une avec workout_cancel avant d'en ajouter.")
        }
        await WorkoutScheduler.shared.schedule(plan, at: at)
        let saved = await WorkoutScheduler.shared.scheduledWorkouts.contains { $0.plan.id == plan.id }
        guard saved else {
            throw DeviceToolError("\(device) n'a pas enregistré la séance : demande à l'utilisateur d'ouvrir l'app Fitness une fois, puis réessaie.")
        }
        guard case let .object(fields) = draft.json() else { return .object(["scheduled": draft.json()]) }
        var out = fields
        out["date"] = .string(HealthFormat.time(Self.date(at) ?? draft.date ?? Date()))
        return .object(["scheduled": .object(out), "note": .string("La séance est dans l'app Fitness de l'iPhone et dans l'app Exercice de l'Apple Watch.")])
    }

    private func scheduled() async throws -> JSONValue {
        let plans = await WorkoutScheduler.shared.scheduledWorkouts
        return .fields([
            "count": .number(Double(plans.count)),
            "max": .number(Double(WorkoutScheduler.maxAllowedScheduledWorkoutCount)),
            "workouts": .array(plans.sorted { (Self.date($0.date) ?? .distantPast) < (Self.date($1.date) ?? .distantPast) }.map(Self.describe)),
        ])
    }

    private func cancel(_ args: DeviceToolArgs) async throws -> JSONValue {
        let plans = await WorkoutScheduler.shared.scheduledWorkouts
        guard !plans.isEmpty else { throw DeviceToolError("Aucune séance programmée sur \(device).") }
        if args.bool("all") == true {
            await WorkoutScheduler.shared.removeAllWorkouts()
            return .object(["cancelled": .number(Double(plans.count))])
        }
        let name = args.string("name")
        let day = try DeviceToolDate.require(args, "date").map { Calendar.current.startOfDay(for: $0.date) }
        guard name != nil || day != nil else { throw DeviceToolError("Donne name, date, ou all: true (voir workout_scheduled).") }
        let matches = plans.filter { plan in
            let matchesName = name.map { Self.name(plan) .localizedCaseInsensitiveContains($0) } ?? true
            let matchesDay = day.map { d in Self.date(plan.date).map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false } ?? true
            return matchesName && matchesDay
        }
        guard !matches.isEmpty else { throw DeviceToolError("Aucune séance programmée ne correspond (voir workout_scheduled).") }
        for match in matches { await WorkoutScheduler.shared.remove(match.plan, at: match.date) }
        return .object(["cancelled": .array(matches.map(Self.describe))])
    }

    // MARK: WorkoutKit

    static func describe(_ plan: ScheduledWorkoutPlan) -> JSONValue {
        .fields([
            "name": .string(name(plan)),
            "activity": .string(AppleHealthTools.name(plan.plan.workout.activity)),
            "date": .str(date(plan.date).map { HealthFormat.time($0) }),
            "complete": plan.complete ? .bool(true) : nil,
        ])
    }

    static func name(_ plan: ScheduledWorkoutPlan) -> String {
        if case let .custom(custom) = plan.plan.workout, let name = custom.displayName, !name.isEmpty { return name }
        return AppleHealthTools.french(plan.plan.workout.activity)
    }

    /// WorkoutKit schedules on wall-clock fields, not an instant.
    static func dateComponents(_ date: Date, calendar: Calendar = .current) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    static func date(_ components: DateComponents, calendar: Calendar = .current) -> Date? {
        calendar.date(from: components)
    }

    static func custom(_ draft: WorkoutPlanDraft) throws -> CustomWorkout {
        let blocks = draft.blocks.map { block in
            IntervalBlock(steps: block.steps.map { IntervalStep($0.purpose == .recovery ? .recovery : .work, step: step($0)) }, iterations: max(block.iterations, 1))
        }
        return CustomWorkout(
            activity: activity(draft.sport),
            location: draft.place == .indoor ? .indoor : .outdoor,
            displayName: draft.name,
            warmup: draft.warmup.map(step),
            blocks: blocks,
            cooldown: draft.cooldown.map(step)
        )
    }

    private static func step(_ draft: WorkoutDraftStep) -> WorkoutKit.WorkoutStep {
        let goal: WorkoutKit.WorkoutGoal = switch draft.goal {
        case let .distance(meters): .distance(meters, .meters)
        case let .time(seconds): .time(seconds, .seconds)
        case .open: .open
        }
        return WorkoutKit.WorkoutStep(goal: goal, alert: alert(draft.target), displayName: draft.name)
    }

    /// WorkoutKit traps on a range whose bounds are equal or out of order, so each one is built from ordered bounds
    /// and a single-value target becomes a threshold alert instead of a range.
    private static func alert(_ target: WorkoutStepTarget?) -> (any WorkoutAlert)? {
        switch target {
        case nil: nil
        case let .pace(secondsPerKm): SpeedThresholdAlert.speed(speed(secondsPerKm), unit: .metersPerSecond, metric: .current)
        case let .paceRange(fast, slow):
            // A quicker pace is a higher speed: the fast end is the range's upper bound.
            speed(slow) < speed(fast)
                ? SpeedRangeAlert.speed(speed(slow)...speed(fast), unit: .metersPerSecond, metric: .current)
                : SpeedThresholdAlert.speed(speed(fast), unit: .metersPerSecond, metric: .current)
        case let .heartRateZone(zone): HeartRateZoneAlert.heartRate(zone: zone)
        case let .heartRateRange(low, high): low < high ? HeartRateRangeAlert.heartRate(low...high) : HeartRateRangeAlert.heartRate(low...(low + 1))
        // A ceiling still needs a positive floor.
        case let .heartRateCeiling(high): HeartRateRangeAlert.heartRate(1...high)
        }
    }

    private static func speed(_ secondsPerKm: Double) -> Double { 1000 / secondsPerKm }

    private static func activity(_ sport: WorkoutPlanDraft.Sport) -> HKWorkoutActivityType {
        switch sport {
        case .running: .running
        case .cycling: .cycling
        case .walking: .walking
        case .swimming: .swimming
        case .rowing: .rowing
        case .elliptical: .elliptical
        }
    }
}
#endif
