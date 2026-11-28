import SwiftUI

/// `::workout`: headline figures, heart rate zones, then laps or exercises.
struct WorkoutCard: View {
    let payload: WorkoutPayload

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            CardHeader(symbol: payload.sportSymbol, tint: .accent, title: title, subtitle: subtitle) {
                if let badge {
                    HStack(spacing: Spacing.xxs) {
                        if payload.live { Circle().fill(Color.accent).frame(width: 6, height: 6) }
                        Text(badge).lineLimit(1)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentInk)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentSoft, in: Capsule())
                }
            }
            let stats = self.stats
            if !stats.isEmpty {
                TileGrid(minimum: 92) {
                    ForEach(stats, id: \.label) { stat in
                        StatTile(label: stat.label, value: stat.value, unit: stat.unit)
                    }
                }
            }
            if !payload.zones.isEmpty { HeartRateZones(zones: payload.zones) }
            if !payload.laps.isEmpty { WorkoutLaps(laps: payload.laps) }
            if !payload.exercises.isEmpty { WorkoutExercises(exercises: payload.exercises) }
            if let note = payload.note { CardNote(text: note) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: String {
        payload.title ?? payload.sport.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? String(localized: "Workout")
    }

    private var subtitle: String? {
        [CardDate.label(payload.date), payload.time].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private var badge: String? {
        payload.status ?? (payload.live ? String(localized: "In progress") : nil)
    }

    private struct Stat { let label: String; let value: String; var unit: String? }

    private var stats: [Stat] {
        var stats: [Stat] = []
        func add(_ label: String, _ quantity: CardQuantity?, maxFraction: Int = 1) {
            guard let quantity else { return }
            stats.append(Stat(label: label, value: quantity.value(maxFraction: maxFraction), unit: quantity.text == nil ? quantity.unit : nil))
        }
        if let duration = payload.duration { stats.append(Self.duration(duration)) }
        add(String(localized: "Distance"), payload.distance, maxFraction: 2)
        if let pace = payload.pace {
            stats.append(Stat(label: String(localized: "Pace"), value: pace.text ?? Self.minutesAndSeconds(pace.number ?? 0), unit: pace.text == nil ? pace.unit : nil))
        } else {
            add(String(localized: "Speed"), payload.speed)
        }
        add(String(localized: "Calories"), payload.calories, maxFraction: 0)
        add(String(localized: "Avg. heart rate"), payload.averageHeartRate, maxFraction: 0)
        add(String(localized: "Max heart rate"), payload.maxHeartRate, maxFraction: 0)
        add(String(localized: "Elevation"), payload.elevation, maxFraction: 0)
        add(String(localized: "Effort"), payload.effort)
        return stats
    }

    /// A number of minutes: "52 min" or "1 h 05".
    private static func duration(_ quantity: CardQuantity) -> Stat {
        let label = String(localized: "Duration")
        guard quantity.text == nil, let minutes = quantity.number else { return Stat(label: label, value: quantity.value()) }
        let total = Int(minutes.rounded())
        guard total >= 60 else { return Stat(label: label, value: "\(total)", unit: "min") }
        return Stat(label: label, value: String(format: "%d h %02d", total / 60, total % 60))
    }

    /// 4.5 minutes → "4:30".
    static func minutesAndSeconds(_ minutes: Double) -> String {
        let seconds = Int((minutes * 60).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private enum ZoneColors {
    static let all: [Color] = [Color(hex: 0x94A3B8), Color(hex: 0x3B82F6), Color(hex: 0x22A06B), Color(hex: 0xF59E0B), Color(hex: 0xE5484D)]

    /// Zone 1 is the easiest and the last zone the hardest, however many zones the bot gives.
    static func color(_ index: Int, of count: Int) -> Color {
        guard count > 1 else { return all[2] }
        let position = Double(index) / Double(count - 1) * Double(all.count - 1)
        return all[min(all.count - 1, max(0, Int(position.rounded())))]
    }
}

private struct HeartRateZones: View {
    let zones: [WorkoutZone]

    var body: some View {
        let total = zones.reduce(0) { $0 + $1.weight }
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Kicker(text: String(localized: "Heart rate zones"), symbol: "heart.fill", tint: Color.text2)
            if total > 0 {
                GeometryReader { proxy in
                    let gaps = CGFloat(zones.filter { $0.weight > 0 }.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(Array(zones.enumerated()), id: \.offset) { index, zone in
                            if zone.weight > 0 {
                                Rectangle()
                                    .fill(ZoneColors.color(index, of: zones.count))
                                    .frame(width: max(2, (proxy.size.width - gaps) * zone.weight / total))
                            }
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: Spacing.xxs) {
                ForEach(Array(zones.enumerated()), id: \.offset) { index, zone in
                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            Circle().fill(ZoneColors.color(index, of: zones.count)).frame(width: 6, height: 6)
                            Text(zone.label).font(.caption2.weight(.bold)).foregroundStyle(Color.text2).lineLimit(1)
                        }
                        Text(detail(zone)).font(.caption.monospacedDigit()).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func detail(_ zone: WorkoutZone) -> String {
        if let detail = zone.detail { return detail }
        if let minutes = zone.minutes { return "\(Int(minutes.rounded())) min" }
        if let percent = zone.percent { return "\(Int(percent.rounded()))%" }
        return ""
    }
}

private struct WorkoutLaps: View {
    let laps: [WorkoutLap]

    var body: some View {
        let seconds = laps.map { $0.time.flatMap(Self.seconds) }
        let fastest = seconds.compactMap { $0 }.min()
        let slowest = seconds.compactMap { $0 }.max()
        let showsBars = seconds.allSatisfy { $0 != nil } && laps.count > 1
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Kicker(text: String(localized: "Laps"), symbol: "flag.checkered", tint: Color.text2)
            Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.xs) {
                ForEach(Array(laps.enumerated()), id: \.offset) { index, lap in
                    GridRow {
                        Text(lap.label).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Color.text2)
                        if laps.contains(where: { $0.distance != nil }) {
                            Text(lap.distance ?? "").font(.caption.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                        }
                        if showsBars, let lapSeconds = seconds[index], let fastest, let slowest {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(lapSeconds == fastest ? Color.accent : Color.accent.opacity(0.35))
                                    .frame(width: proxy.size.width * Self.share(lapSeconds, fastest: fastest, slowest: slowest), height: 6)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(minWidth: 40, maxWidth: .infinity)
                            .frame(height: 16)
                            .accessibilityHidden(true)
                        }
                        Text(lap.time ?? "").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink).lineLimit(1)
                            .gridColumnAlignment(.trailing)
                        if laps.contains(where: { $0.pace != nil }) {
                            Text(lap.pace ?? "").font(.caption.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                                .gridColumnAlignment(.trailing)
                        }
                        if laps.contains(where: { $0.heartRate != nil }) {
                            HStack(spacing: 2) {
                                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Color.bad.opacity(0.8))
                                Text(lap.heartRate ?? "").font(.caption.monospacedDigit()).foregroundStyle(Color.text2)
                            }
                            .lineLimit(1)
                            .opacity(lap.heartRate == nil ? 0 : 1)
                            .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }

    /// Laps a few seconds apart would draw bars of the same length: the slowest gets 40 % of the width, the fastest all of it.
    static func share(_ seconds: Double, fastest: Double, slowest: Double) -> CGFloat {
        guard slowest > fastest else { return 1 }
        return 0.4 + 0.6 * (slowest - seconds) / (slowest - fastest)
    }

    /// "3:36", "1:02:10" or "95" seconds.
    static func seconds(_ time: String) -> Double? {
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0.prefix { $0.isNumber || $0 == "." }) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let total = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? total : nil
    }
}

private struct WorkoutExercises: View {
    let exercises: [WorkoutExercise]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Kicker(text: String(localized: "Exercises"), symbol: "dumbbell.fill", tint: Color.text2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(exercises.enumerated()), id: \.offset) { index, exercise in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                            Spacer(minLength: Spacing.xs)
                            if !exercise.sets.isEmpty {
                                Text("\(exercise.sets.count) sets").font(.caption).foregroundStyle(Color.text2)
                            }
                        }
                        if !exercise.sets.isEmpty {
                            WrapLayout(spacing: Spacing.xxs, lineSpacing: Spacing.xxs) {
                                ForEach(Array(exercise.sets.enumerated()), id: \.offset) { _, set in
                                    Text(Self.label(set))
                                        .font(.caption.weight(.medium).monospacedDigit())
                                        .foregroundStyle(Color.ink)
                                        .padding(.horizontal, Spacing.xs).padding(.vertical, 3)
                                        .background(Color.canvas, in: Capsule())
                                }
                            }
                        }
                        if let note = exercise.note {
                            Text(note).font(.caption).foregroundStyle(Color.text2)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    if index < exercises.count - 1 { Divider().overlay(Color.line) }
                }
            }
        }
    }

    /// "8 × 70 kg", "12 reps", "70 kg" or the set's own text.
    static func label(_ set: WorkoutSet) -> String {
        let weight = set.weight.map { $0.line() }
        switch (set.reps, weight) {
        case let (reps?, weight?): return "\(reps) × \(weight)"
        case let (reps?, nil): return String(localized: "\(reps) reps")
        case let (nil, weight?): return weight
        default: return set.text ?? ""
        }
    }
}
