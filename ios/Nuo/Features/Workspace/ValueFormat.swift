import SwiftUI

/// Display of data values by column type, in the user's locale.
enum ValueFormat {
    static var locale: Locale { .current }

    static var monthNames: [String] {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar.monthSymbols
    }

    static func money(_ value: Double, cents: Bool = true) -> String {
        value.formatted(.currency(code: "EUR").locale(locale).precision(.fractionLength(cents ? 2 : 0)))
    }

    /// "12,4 k€" for chart axes and tight places.
    static func compactMoney(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 { return "\((value / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))) M€" }
        if magnitude >= 10_000 { return "\((value / 1_000).formatted(.number.precision(.fractionLength(0)).locale(locale))) k€" }
        if magnitude >= 1_000 { return "\((value / 1_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale))) k€" }
        return money(value, cents: false)
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    /// Percent columns hold a fraction (0.2 = 20 %), like Notion.
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }

    static func parseDate(_ text: String) -> Date? {
        if text.count == 10 {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        }
        return NuoJSON.parseDate(text)
    }

    static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "today", "yesterday", "3 days ago", "in 5 days", "Oct 12", "Oct 12, 2025".
    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return String(localized: "today")
        case -1: return String(localized: "yesterday")
        case 1: return String(localized: "tomorrow")
        case -6 ... -2: return String(localized: "\(-days) days ago")
        case 2...6: return String(localized: "in \(days) days")
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let style = Date.FormatStyle(locale: locale).day().month(.abbreviated)
            return date.formatted(sameYear ? style : style.year())
        }
    }

    /// Within a week either way, where "3 days ago" says more than the date.
    static func isNear(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
        return abs(days) <= 6
    }

    static func longDate(_ date: Date, time: Bool = false) -> String {
        let style = Date.FormatStyle(locale: locale).weekday(.wide).day().month(.wide).year()
        return time ? date.formatted(style.hour().minute()) : date.formatted(style)
    }

    /// Plain text for a value of a column (lists, search, history).
    static func text(_ value: JSONValue, column: DataColumn?, refTitle: String? = nil) -> String {
        if value.isNull { return "—" }
        guard let column else { return value.string ?? "—" }
        switch column.type {
        case .money: return value.double.map { money($0) } ?? "—"
        case .number: return value.double.map(number) ?? "—"
        case .percent: return value.double.map(percent) ?? "—"
        case .date: return value.string.flatMap(parseDate).map { $0.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).year()) } ?? "—"
        case .datetime: return value.string.flatMap(parseDate).map { $0.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).hour().minute()) } ?? "—"
        case .bool: return value.bool == true ? String(localized: "Yes") : String(localized: "No")
        case .select: return option(value.string, in: column)?.display ?? value.string ?? "—"
        case .multiselect: return value.stringArray.map { option($0, in: column)?.display ?? $0 }.joined(separator: ", ")
        case .ref: return refTitle ?? value.string ?? "—"
        case .refs:
            if let refTitle, !refTitle.isEmpty { return refTitle }
            let count = value.stringArray.count
            return count == 0 ? "—" : String(localized: "\(count) items")
        case .file: return files(value).map(\.name).joined(separator: ", ")
        default: return value.string ?? "—"
        }
    }

    static func option(_ value: String?, in column: DataColumn) -> DataOption? {
        guard let value else { return nil }
        return column.options?.first { $0.value == value }
    }

    static func files(_ value: JSONValue) -> [DataFileRef] {
        guard let data = try? JSONEncoder().encode(value) else { return [] }
        if let list = try? JSONDecoder().decode([DataFileRef].self, from: data) { return list }
        if let single = try? JSONDecoder().decode(DataFileRef.self, from: data) { return [single] }
        return []
    }

    /// Stable fallback color for options without one.
    static func color(for option: DataOption) -> Color {
        if let hex = option.color, let color = Color(hexString: hex) { return color }
        if let named = option.color.flatMap(namedColor) { return named }
        let palette: [UInt32] = [0x3B82F6, 0x1F9D57, 0xF59E0B, 0xA855F7, 0xEC4899, 0x14B8A6, 0xFF6A2B, 0x8B8A91]
        let hash = option.value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hex: palette[hash % palette.count])
    }

    /// Notion color names.
    private static func namedColor(_ name: String) -> Color? {
        let map: [String: UInt32] = [
            "gray": 0x8B8A91, "brown": 0x9A6B4F, "orange": 0xFF6A2B, "yellow": 0xE5A800, "green": 0x1F9D57,
            "blue": 0x3B82F6, "purple": 0xA855F7, "pink": 0xEC4899, "red": 0xE5484D, "default": 0x8B8A91,
        ]
        return map[name.lowercased()].map { Color(hex: $0) }
    }

    /// Formats a dashboard value with the block's `format`.
    static func formatted(_ value: JSONValue, format: String?) -> String {
        switch format {
        case "money": return value.double.map { money($0) } ?? value.string ?? "—"
        case "percent": return value.double.map(percent) ?? value.string ?? "—"
        case "date": return value.string.flatMap(parseDate).map { relativeDay($0) } ?? value.string ?? "—"
        default:
            if case let .number(number) = value { return self.number(number) }
            return value.string ?? "—"
        }
    }

    /// Chart x labels: "2026-03" → "Mar", "2026-03-14" → "Mar 14".
    static func axisLabel(_ value: JSONValue) -> String {
        guard let text = value.string else { return "" }
        if text.count == 7, text.dropFirst(4).first == "-", let year = Int(text.prefix(4)), let month = Int(text.suffix(2)), (1...12).contains(month),
           let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) {
            return date.formatted(Date.FormatStyle(locale: locale).month(.abbreviated))
        }
        if text.count == 10, let date = parseDate(text) {
            return date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated))
        }
        return text
    }
}

/// Colored capsule for a select option.
struct OptionChip: View {
    let option: DataOption
    var compact = false

    var body: some View {
        let color = ValueFormat.color(for: option)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(option.display).lineLimit(1)
        }
        .font((compact ? Font.caption2 : .caption).weight(.semibold))
        .foregroundStyle(color.mix(with: .primary, by: 0.35))
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}
