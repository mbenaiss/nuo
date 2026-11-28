import SwiftUI

/// `::meal`: calories, the macro split, the foods and where the day stands against its goal.
struct MealCard: View {
    let payload: MealPayload

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            CardHeader(symbol: "fork.knife", tint: .good, title: title, subtitle: subtitle) {
                if let calories = payload.calories {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(calories.value(maxFraction: 0))
                            .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        if calories.text == nil, let unit = calories.unit {
                            Text(unit).font(.caption.weight(.medium)).foregroundStyle(Color.text2)
                        }
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
            }
            let macros = self.macros
            if !macros.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    MacroSplit(macros: macros)
                    TileGrid(minimum: 70) {
                        ForEach(macros, id: \.label) { macro in
                            StatTile(label: macro.label, quantity: macro.quantity, dot: macro.color)
                        }
                    }
                }
            }
            if !payload.items.isEmpty { foods }
            if let goal = payload.goal { MealGoal(payload: payload, goal: goal) }
            if let note = payload.note { CardNote(text: note, symbol: "checkmark.seal.fill", tint: .good) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: String {
        payload.name ?? payload.moment ?? String(localized: "Meal")
    }

    private var subtitle: String? {
        [payload.name == nil ? nil : payload.moment, payload.time].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    struct Macro {
        let label: String
        let quantity: CardQuantity
        let color: Color
        /// Calories per gram, for the split; nil for what the split leaves out (fiber).
        let kcalPerGram: Double?
    }

    static let proteinColor = Color(hex: 0x3B82F6)
    static let carbsColor = Color(hex: 0xF59E0B)
    static let fatColor = Color(hex: 0xE0569B)
    static let fiberColor = Color(hex: 0x22A06B)

    private var macros: [Macro] {
        [
            payload.protein.map { Macro(label: String(localized: "Protein"), quantity: $0, color: Self.proteinColor, kcalPerGram: 4) },
            payload.carbs.map { Macro(label: String(localized: "Carbs"), quantity: $0, color: Self.carbsColor, kcalPerGram: 4) },
            payload.fat.map { Macro(label: String(localized: "Fat"), quantity: $0, color: Self.fatColor, kcalPerGram: 9) },
            payload.fiber.map { Macro(label: String(localized: "Fiber"), quantity: $0, color: Self.fiberColor, kcalPerGram: nil) },
        ].compactMap { $0 }
    }

    private var foods: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Kicker(text: String(localized: "Foods"), symbol: "list.bullet", tint: Color.text2)
            VStack(spacing: 0) {
                ForEach(Array(payload.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text(item.name).font(.subheadline).foregroundStyle(Color.ink)
                        if let portion = item.portion {
                            Text(portion).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                        }
                        Spacer(minLength: Spacing.xs)
                        if let calories = item.calories {
                            Text(calories.line(maxFraction: 0)).font(.caption.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    if index < payload.items.count - 1 { Divider().overlay(Color.line) }
                }
            }
        }
    }
}

/// Share of the meal's calories from protein, carbs and fat.
private struct MacroSplit: View {
    let macros: [MealCard.Macro]

    var body: some View {
        let parts = macros.compactMap { macro -> (Color, Double)? in
            guard let perGram = macro.kcalPerGram, let grams = macro.quantity.number, grams > 0 else { return nil }
            return (macro.color, grams * perGram)
        }
        let total = parts.reduce(0) { $0 + $1.1 }
        if parts.count > 1, total > 0 {
            GeometryReader { proxy in
                let width = proxy.size.width - CGFloat(parts.count - 1) * 2
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(part.0).frame(width: max(2, width * part.1 / total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .accessibilityHidden(true)
        }
    }
}

/// Progress of the day against its goal: what was eaten before, then this meal.
private struct MealGoal: View {
    let payload: MealPayload
    let goal: MealTotals

    private struct Row {
        let label: String
        let color: Color
        let meal: Double
        let day: Double?
        let goal: Double
        let unit: String
    }

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Kicker(text: payload.day == nil ? String(localized: "Share of daily goal") : String(localized: "Today"),
                       symbol: "target", tint: Color.text2)
                ForEach(rows, id: \.label) { row in
                    HStack(spacing: Spacing.sm) {
                        Text(row.label).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                            .frame(width: labelWidth, alignment: .leading)
                        bar(row)
                        Text(verbatim: "\(Self.number(row.day ?? row.meal)) / \(Self.number(row.goal)) \(row.unit)")
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.ink).lineLimit(1)
                            .frame(minWidth: valueWidth, alignment: .trailing)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 64
    /// Room for "1,840 / 2,450 kcal", so every bar of the goal ends at the same place.
    @ScaledMetric(relativeTo: .caption) private var valueWidth: CGFloat = 112

    private func bar(_ row: Row) -> some View {
        let total = row.day ?? row.meal
        let before = max(0, total - row.meal)
        return GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.chip)
                HStack(spacing: 0) {
                    Rectangle().fill(row.color.opacity(0.4)).frame(width: width * min(1, before / row.goal))
                    Rectangle().fill(row.color).frame(width: width * max(0, min(1, total / row.goal) - min(1, before / row.goal)))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var rows: [Row] {
        func row(_ label: String, _ color: Color, _ meal: CardQuantity?, _ day: Double?, _ goal: Double?, _ unit: String) -> Row? {
            guard let goal, goal > 0, let value = meal?.number ?? (payload.day == nil ? nil : 0) else { return nil }
            return Row(label: label, color: color, meal: value, day: day, goal: goal, unit: unit)
        }
        let day = payload.day
        return [
            row(String(localized: "Calories"), .accent, payload.calories, day?.calories, goal.calories, "kcal"),
            row(String(localized: "Protein"), MealCard.proteinColor, payload.protein, day?.protein, goal.protein, "g"),
            row(String(localized: "Carbs"), MealCard.carbsColor, payload.carbs, day?.carbs, goal.carbs, "g"),
            row(String(localized: "Fat"), MealCard.fatColor, payload.fat, day?.fat, goal.fat, "g"),
            row(String(localized: "Fiber"), MealCard.fiberColor, payload.fiber, day?.fiber, goal.fiber, "g"),
        ].compactMap { $0 }
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
