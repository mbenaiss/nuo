#if os(iOS)
import Foundation
import HealthKit

/// The `health_*` tools: the bots read this iPhone's Santé data, in the moment, and nothing is kept outside it
/// (docs/health.md). Read-only: Nuo asks Santé for no right to write. Off the main actor: a year of samples takes
/// seconds to walk through.
final class AppleHealthTools: Sendable {
    private let store = HKHealthStore()
    /// The iPhone's name, as the refusals a bot reads name it; read once, on the main actor.
    private let device: String

    init(device: String) { self.device = device }

    /// Everything Nuo ever asks Santé for. Santé never says which of these the user granted, so a read that comes
    /// back empty means « nothing recorded » or « refused » alike, and the tools say so.
    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .distanceCycling, .activeEnergyBurned, .basalEnergyBurned,
            .appleExerciseTime, .appleStandTime, .flightsClimbed,
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .walkingHeartRateAverage, .respiratoryRate,
            .vo2Max, .bodyMass, .height, .bodyFatPercentage, .leanBodyMass,
        ]
        for id in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { types.insert(type) }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        return types
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Santé only tells whether the question has already been put to the user, never what they answered.
    static func wasAsked(store: HKHealthStore = HKHealthStore()) async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status == .unnecessary
    }

    static func requestAccess(store: HKHealthStore = HKHealthStore()) async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            return false
        }
    }

    func perform(_ tool: String, _ args: DeviceToolArgs) async throws -> JSONValue {
        guard Self.isAvailable else { throw DeviceToolError("Santé n'existe pas sur \(device).") }
        guard await Self.wasAsked(store: store) else {
            throw DeviceToolError("Nuo n'a pas encore demandé l'accès à Santé sur \(device) : demande à l'utilisateur de l'autoriser dans Nuo, Réglages › Accès des bots.")
        }
        switch tool {
        case "health_summary": return try await summary(args)
        case "health_activity":
            let window = try HealthRange.window(args, defaultDays: 7)
            return HealthReport.activity(try await activity(window), window: window)
        case "health_heart":
            let window = try HealthRange.window(args, defaultDays: 7)
            return HealthReport.heart(try await heart(window), vo2Max: try await latest(.vo2Max, unit: vo2Unit)?.value, window: window)
        case "health_sleep":
            let window = try HealthRange.window(args, defaultDays: 7, key: "nights")
            return HealthReport.sleep(try await sleep(window), window: window)
        case "health_workouts":
            let window = try HealthRange.window(args, defaultDays: 14)
            let max = args.int("max", default: 30, range: 1...200)
            let found = try await workouts(window, activity: args.string("type"))
            return HealthReport.workouts(Array(found.suffix(max)), window: window, truncated: found.count > max)
        case "health_body":
            let window = try HealthRange.window(args, defaultDays: 90)
            return try await body(window).json()
        default: throw DeviceToolError("Outil inconnu \(tool).")
        }
    }

    private func summary(_ args: DeviceToolArgs) async throws -> JSONValue {
        let window = try HealthRange.window(args, defaultDays: 7)
        async let activity = activity(window)
        async let heart = heart(window)
        async let sleep = sleep(window)
        async let workouts = workouts(window, activity: nil)
        return HealthReport.summary(
            activity: try await activity, heart: try await heart, nights: try await sleep,
            workouts: try await workouts, body: try await body(window), window: window
        )
    }

    // MARK: Days

    private func activity(_ window: HealthWindow) async throws -> [ActivityDay] {
        async let steps = daily(.stepCount, .count(), in: window, options: .cumulativeSum)
        async let walked = daily(.distanceWalkingRunning, .meter(), in: window, options: .cumulativeSum)
        async let active = daily(.activeEnergyBurned, .kilocalorie(), in: window, options: .cumulativeSum)
        async let resting = daily(.basalEnergyBurned, .kilocalorie(), in: window, options: .cumulativeSum)
        async let exercise = daily(.appleExerciseTime, .minute(), in: window, options: .cumulativeSum)
        async let stand = daily(.appleStandTime, .minute(), in: window, options: .cumulativeSum)
        async let flights = daily(.flightsClimbed, .count(), in: window, options: .cumulativeSum)
        let (s, w, a, r, e, st, f) = (try await steps, try await walked, try await active, try await resting, try await exercise, try await stand, try await flights)
        return HealthRange.days(window).map { day in
            ActivityDay(date: day, steps: s[day], distanceMeters: w[day], activeEnergy: a[day], restingEnergy: r[day],
                        exerciseMinutes: e[day], standMinutes: st[day], flightsClimbed: f[day])
        }
    }

    private func heart(_ window: HealthWindow) async throws -> [HeartDay] {
        async let resting = daily(.restingHeartRate, beatsPerMinute, in: window, options: .discreteAverage)
        async let hrv = daily(.heartRateVariabilitySDNN, .secondUnit(with: .milli), in: window, options: .discreteAverage)
        async let walking = daily(.walkingHeartRateAverage, beatsPerMinute, in: window, options: .discreteAverage)
        async let low = daily(.heartRate, beatsPerMinute, in: window, options: .discreteMin)
        async let high = daily(.heartRate, beatsPerMinute, in: window, options: .discreteMax)
        async let breaths = daily(.respiratoryRate, beatsPerMinute, in: window, options: .discreteAverage)
        let (r, v, w, lo, hi, b) = (try await resting, try await hrv, try await walking, try await low, try await high, try await breaths)
        return HealthRange.days(window).map { day in
            HeartDay(date: day, restingHeartRate: r[day], heartRateVariability: v[day], walkingHeartRate: w[day],
                     minHeartRate: lo[day], maxHeartRate: hi[day], respiratoryRate: b[day])
        }
    }

    private var beatsPerMinute: HKUnit { HKUnit.count().unitDivided(by: .minute()) }
    private var vo2Unit: HKUnit { HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())) }

    /// One figure per local day, from Santé's own per-day buckets.
    private func daily(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, in window: HealthWindow, options: HKStatisticsOptions) async throws -> [Date: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictStartDate)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: options,
            anchorDate: window.start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await run { try await descriptor.result(for: self.store) }
        var out: [Date: Double] = [:]
        collection?.enumerateStatistics(from: window.start, to: window.end) { statistics, _ in
            let quantity = switch options {
            case .cumulativeSum: statistics.sumQuantity()
            case .discreteMin: statistics.minimumQuantity()
            case .discreteMax: statistics.maximumQuantity()
            default: statistics.averageQuantity()
            }
            guard let quantity else { return }
            out[calendar.startOfDay(for: statistics.startDate)] = quantity.doubleValue(for: unit)
        }
        return out
    }

    // MARK: Sleep, sessions, measurements

    private func sleep(_ window: HealthWindow) async throws -> [SleepNight] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        // A night starts the evening before the window's first morning.
        let from = Calendar.current.date(byAdding: .hour, value: -12, to: window.start) ?? window.start
        let predicate = HKQuery.predicateForSamples(withStart: from, end: window.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: 2000
        )
        let samples = try await run { try await descriptor.result(for: self.store) } ?? []
        let pieces = samples.compactMap { sample -> SleepPiece? in
            guard let stage = Self.stage(sample.value) else { return nil }
            return SleepPiece(start: sample.startDate, end: sample.endDate, stage: stage)
        }
        return HealthSleep.nights(from: pieces).filter { $0.date >= window.start && $0.date < window.end }
    }

    private static func stage(_ value: Int) -> SleepPiece.Stage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: .inBed
        case .awake: .awake
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .asleep
        default: nil
        }
    }

    private func workouts(_ window: HealthWindow, activity type: String?) async throws -> [WorkoutSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate)], limit: 200)
        let found = try await run { try await descriptor.result(for: self.store) } ?? []
        let wanted = type?.lowercased()
        return found.compactMap { workout in
            let name = Self.name(workout.workoutActivityType)
            if let wanted, !name.localizedCaseInsensitiveContains(wanted), !Self.french(workout.workoutActivityType).localizedCaseInsensitiveContains(wanted) { return nil }
            let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()
                ?? workout.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()
            let heart = workout.statistics(for: HKQuantityType(.heartRate))
            return WorkoutSummary(
                id: workout.uuid.uuidString,
                activity: name,
                start: workout.startDate,
                end: workout.endDate,
                distanceMeters: distance?.doubleValue(for: .meter()),
                activeEnergy: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                averageHeartRate: heart?.averageQuantity()?.doubleValue(for: beatsPerMinute),
                maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: beatsPerMinute),
                elevationMeters: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
                indoor: workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool,
                source: workout.sourceRevision.source.name
            )
        }
    }

    private func body(_ window: HealthWindow) async throws -> BodySnapshot {
        async let weight = latest(.bodyMass, unit: .gramUnit(with: .kilo))
        async let height = latest(.height, unit: .meterUnit(with: .centi))
        async let fat = latest(.bodyFatPercentage, unit: .percent())
        async let lean = latest(.leanBodyMass, unit: .gramUnit(with: .kilo))
        async let vo2 = latest(.vo2Max, unit: vo2Unit)
        async let earlier = first(.bodyMass, unit: .gramUnit(with: .kilo), in: window)
        var snapshot = BodySnapshot()
        snapshot.weightKg = try await weight
        snapshot.heightCm = try await height
        if let fat = try await fat { snapshot.bodyFatPercent = (value: fat.value * 100, date: fat.date) }
        snapshot.leanMassKg = try await lean
        snapshot.vo2Max = try await vo2
        snapshot.weightEarlierKg = try await earlier?.value
        return snapshot
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> (value: Double, date: Date)? {
        try await one(id, unit: unit, sort: SortDescriptor(\HKQuantitySample.startDate, order: .reverse), predicate: nil)
    }

    private func first(_ id: HKQuantityTypeIdentifier, unit: HKUnit, in window: HealthWindow) async throws -> (value: Double, date: Date)? {
        try await one(id, unit: unit, sort: SortDescriptor(\HKQuantitySample.startDate),
                      predicate: HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: []))
    }

    private func one(_ id: HKQuantityTypeIdentifier, unit: HKUnit, sort: SortDescriptor<HKQuantitySample>, predicate: NSPredicate?) async throws -> (value: Double, date: Date)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)], sortDescriptors: [sort], limit: 1)
        guard let sample = (try await run { try await descriptor.result(for: self.store) })?.first else { return nil }
        return (value: sample.quantity.doubleValue(for: unit), date: sample.startDate)
    }

    /// Santé refuses a type the user never granted with an error of its own: that reads as « nothing recorded ».
    private func run<T>(_ query: () async throws -> T) async throws -> T? {
        do {
            return try await query()
        } catch let error as HKError {
            switch error.code {
            case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorNoData: return nil
            case .errorDatabaseInaccessible:
                throw DeviceToolError("Santé est verrouillé sur \(device) : les données ne sont lisibles que quand l'iPhone est déverrouillé.")
            default: throw DeviceToolError("Santé n'a pas répondu : \(error.localizedDescription)")
            }
        }
    }

    // MARK: Names

    static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "running"
        case .walking: "walking"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .hiking: "hiking"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength"
        case .highIntensityIntervalTraining: "hiit"
        case .yoga: "yoga"
        case .rowing: "rowing"
        case .elliptical: "elliptical"
        case .stairClimbing, .stairs: "stairs"
        case .soccer: "soccer"
        case .tennis: "tennis"
        case .basketball: "basketball"
        case .boxing, .kickboxing: "boxing"
        case .dance, .cardioDance: "dance"
        case .pilates: "pilates"
        case .climbing: "climbing"
        case .skatingSports: "skating"
        case .downhillSkiing, .crossCountrySkiing, .snowSports: "skiing"
        case .coreTraining: "core"
        case .flexibility, .cooldown: "stretching"
        case .mindAndBody: "breathing"
        default: "other"
        }
    }

    static func french(_ type: HKWorkoutActivityType) -> String {
        switch name(type) {
        case "running": "course"
        case "walking": "marche"
        case "cycling": "vélo"
        case "swimming": "natation"
        case "hiking": "randonnée"
        case "strength": "musculation"
        case "rowing": "rameur"
        case "elliptical": "elliptique"
        case "stairs": "escaliers"
        case "soccer": "football"
        case "basketball": "basket"
        case "boxing": "boxe"
        case "dance": "danse"
        case "climbing": "escalade"
        case "skating": "patinage"
        case "skiing": "ski"
        case "stretching": "étirements"
        case "breathing": "respiration"
        case "core": "gainage"
        default: name(type)
        }
    }
}
#endif
