import Foundation

/// The first name Nuo greets with. A demo always shows Alex and never writes over the name saved on the device.
struct UserNamePreference {
    static let key = AppIdentity.local(.userName)
    static let demoName = "Alex"

    let defaults: UserDefaults
    let isDemo: Bool

    /// For code that reads the name outside `SessionStore` (dictation terms, Apple Watch questions).
    static var standard: UserNamePreference {
        UserNamePreference(defaults: .standard, isDemo: ProcessInfo.processInfo.arguments.contains("-demo"))
    }

    func load() -> String {
        isDemo ? Self.demoName : defaults.string(forKey: Self.key) ?? ""
    }

    func save(_ name: String) {
        guard !isDemo else { return }
        defaults.set(name, forKey: Self.key)
    }
}
