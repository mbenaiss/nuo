import Foundation
import Synchronization

/// ISO-8601 dates on the wire (`NuoJSON` of the app, the Mac and the watch).
enum ISO8601Wire {
    // Creating an ISO8601DateFormatter costs ~0.2 ms: one per date made large payloads take seconds to code.
    private static let formatter: Mutex<ISO8601DateFormatter> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Mutex(formatter)
    }()

    static func parse(_ text: String) -> Date? {
        if let date = text.utf8.withContiguousStorageIfAvailable(canonicalDate) ?? nil { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func format(_ date: Date) -> String {
        formatter.withLock { $0.string(from: date) }
    }

    /// `2026-10-17T09:30:00.123Z` and `…+02:00`, the shapes the gateway sends, read without a formatter (even a
    /// shared one takes ~70 µs per date). Same result as `ISO8601DateFormatter`; anything else goes to it (nil).
    private static func canonicalDate(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        let count = bytes.count
        guard count >= 20, count <= 29 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        // The formatter switches to the Julian calendar before 1582: older years take the slow path.
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              year >= 1600, (1...12).contains(month), hour < 24, minute < 60, second < 60
        else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= monthDays[month - 1] else { return nil }
        var index = 19
        var millis = 0
        if bytes[index] == UInt8(ascii: ".") {
            guard count >= index + 5, let value = number(index + 1, 3) else { return nil }
            millis = value
            index += 4
        }
        let offset: Int
        if index == count - 1, bytes[index] == UInt8(ascii: "Z") {
            offset = 0
        } else if index == count - 6, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"), bytes[index + 3] == UInt8(ascii: ":"),
                  let hours = number(index + 1, 2), let minutes = number(index + 4, 2), hours < 24, minutes < 60 {
            offset = (hours * 3600 + minutes * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)
        } else {
            return nil
        }
        // Days since 1970-01-01 (H. Hinnant's days_from_civil).
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = shiftedYear / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + Double(millis) / 1000)
    }
}
