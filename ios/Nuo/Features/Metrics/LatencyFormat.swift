import Foundation

/// Wording of the "Bot Speed" figures.
enum LatencyFormat {
    /// "0.8 s" under ten seconds, "12 s" under a minute, then "1 min 05"; a dash when unknown.
    static func duration(_ ms: Int?, locale: Locale = .current) -> String {
        guard let ms else { return "—" }
        let tenths = (Double(ms) / 100).rounded() / 10
        if tenths < 10 { return "\(tenths.formatted(.number.precision(.fractionLength(1)).locale(locale))) s" }
        let seconds = Int((Double(ms) / 1000).rounded())
        if seconds < 60 { return "\(seconds) s" }
        return String(format: "%d min %02d", seconds / 60, seconds % 60)
    }

    /// "3" or "2.5": average steps, chart axis seconds.
    static func decimal(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    static func responses(_ count: Int) -> String {
        count == 1 ? String(localized: "1 response") : String(localized: "\(count) responses")
    }

    /// The gateway's `YYYY-MM-DD` as the start of that day here.
    static func date(day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
