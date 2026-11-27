import Foundation

/// Text of the alert shown when ⌘Q would lose work registered with `QuitCoordinator`.
enum QuitPrompt {
    static let title = String(localized: "Quit Nuo?")
    static let confirm = String(localized: "Quit Anyway")
    static let cancel = String(localized: "Cancel")

    /// nil when nothing would be lost: the app then quits without asking.
    static func message(for reasons: [String]) -> String? {
        let lines = reasons.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if lines.count == 1 { return lines[0] }
        return lines.map { "• \($0)" }.joined(separator: "\n")
    }
}
