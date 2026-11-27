import Foundation

/// The refusal a bot reads, in French: it is the tool's answer, not a crash.
struct DeviceToolError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Arguments of a device tool call, as the bot sent them (numbers may arrive as strings and the reverse).
struct DeviceToolArgs: Sendable {
    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue]) { self.raw = raw }

    func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return value != .null
    }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case let .string(v): let t = v.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
        case let .number(v): return v.rounded() == v ? String(Int(v)) : String(v)
        default: return nil
        }
    }

    func number(_ key: String) -> Double? {
        switch raw[key] {
        case let .number(v): v
        case let .string(v): Double(v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        default: nil
        }
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let n = number(key), n.isFinite else { return fallback }
        return min(max(Int(n.rounded()), range.lowerBound), range.upperBound)
    }

    func bool(_ key: String) -> Bool? {
        switch raw[key] {
        case let .bool(v): v
        case let .string(v): ["true", "oui", "1"].contains(v.lowercased()) ? true : ["false", "non", "0"].contains(v.lowercased()) ? false : nil
        case let .number(v): v != 0
        default: nil
        }
    }

    func strings(_ key: String) -> [String]? {
        switch raw[key] {
        case let .array(items): items.compactMap { if case let .string(s) = $0 { s } else { nil } }
        case let .string(v): v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: nil
        }
    }

    func numbers(_ key: String) -> [Double]? {
        guard case let .array(items) = raw[key] else { return number(key).map { [$0] } }
        return items.compactMap {
            switch $0 {
            case let .number(v): v
            case let .string(s): Double(s)
            default: nil
            }
        }
    }

    func object(_ key: String) -> DeviceToolArgs? {
        guard case let .object(o) = raw[key] else { return nil }
        return DeviceToolArgs(o)
    }

    /// "ici", "here", "current" or nothing: the device's own position.
    func isHere(_ key: String) -> Bool {
        guard let place = string(key)?.lowercased() else { return true }
        return ["ici", "here", "current", "position actuelle", "ma position"].contains(place)
    }
}

/// Dates as bots write them: a wall-clock time in the device's zone, a day, or ISO 8601 with an offset.
enum DeviceToolDate {
    struct Parsed: Equatable {
        let date: Date
        /// AAAA-MM-JJ: a whole day.
        let dayOnly: Bool
    }

    static func parse(_ text: String, timeZone: TimeZone = .current) -> Parsed? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = /^(\d{4})-(\d{2})-(\d{2})$/
        let local = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/
        if let m = t.wholeMatch(of: day) {
            let c = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3))
            return calendar.date(from: c).map { Parsed(date: $0, dayOnly: true) }
        }
        if let m = t.wholeMatch(of: local) {
            let c = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3), hour: Int(m.4), minute: Int(m.5), second: m.6.flatMap { Int($0) } ?? 0)
            guard let date = calendar.date(from: c), calendar.component(.hour, from: date) == Int(m.4) else { return nil }
            return Parsed(date: date, dayOnly: false)
        }
        if let date = ISO8601Wire.parse(t) { return Parsed(date: date, dayOnly: false) }
        let offset = ISO8601DateFormatter()
        offset.formatOptions = [.withInternetDateTime]
        return offset.date(from: t).map { Parsed(date: $0, dayOnly: false) }
    }

    static func require(_ args: DeviceToolArgs, _ key: String, timeZone: TimeZone = .current) throws -> Parsed? {
        guard let text = args.string(key) else { return nil }
        guard let parsed = parse(text, timeZone: timeZone) else {
            throw DeviceToolError("Date invalide « \(text) » pour \(key) : utilise AAAA-MM-JJTHH:MM, ou AAAA-MM-JJ pour une journée.")
        }
        return parsed
    }

    /// Local time with its offset ("2026-10-28T09:30:00+01:00"), or the bare day.
    static func format(_ date: Date, dayOnly: Bool = false, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = dayOnly ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }
}

/// "#34C759" ↔ 0…1 components.
enum DeviceToolColor {
    static func parse(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func hex(red: Double, green: Double, blue: Double) -> String {
        let c = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
    }
}

extension JSONValue {
    /// An object without the absent fields, so answers stay short for the bot.
    static func fields(_ fields: KeyValuePairs<String, JSONValue?>) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for (k, v) in fields { if let v { o[k] = v } }
        return .object(o)
    }

    static func str(_ value: String?) -> JSONValue? { value.map { .string($0) } }
    static func num(_ value: Double?) -> JSONValue? { value.map { .number($0) } }

    /// Rounded for the bot: four decimals of a degree are ~10 m.
    static func rounded(_ value: Double, _ places: Int) -> JSONValue {
        let p = pow(10, Double(places))
        return .number((value * p).rounded() / p)
    }
}
