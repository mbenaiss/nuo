import Foundation

/// Identifiers that depend on who signs the build, read from the Info.plist keys project.yml fills from
/// Base.xcconfig and Local.xcconfig. Keychain services, widget kinds and queue labels derive from them so that
/// a build signed for another team keeps the same items as before only when it keeps the same identifiers.
enum AppIdentity {
    /// The iPhone and Mac app bundle identifier (`NUO_BUNDLE_ID`), shared by every target as their base.
    static let identifier = value(for: "NuoAppIdentifier") ?? "com.example.nuo"

    /// App group of the app and its extensions (`NUO_APP_GROUP`).
    static let appGroup = value(for: "NuoAppGroup") ?? "group.com.example.nuo"

    /// Gateway address prefilled on the pairing screen (`NUO_DEFAULT_GATEWAY`), empty when the build sets none.
    static let defaultGateway = value(for: "NuoDefaultGateway") ?? ""

    /// The stored gateway, else the build's default; a placeholder that never resolves when neither is set, for
    /// code paths that only run once paired and need a URL to ask the keychain whether they are.
    static var gatewayURL: URL {
        gatewayURL(stored: UserDefaults.standard.string(forKey: "nuo.gatewayURL"), configured: defaultGateway)
    }

    static func gatewayURL(stored: String?, configured: String) -> URL {
        func usable(_ text: String?) -> URL? { URL(string: text ?? "").flatMap { $0.host() == nil ? nil : $0 } }
        return usable(stored) ?? usable(configured) ?? URL(string: "https://gateway.invalid")!
    }

    /// `<identifier>.<suffix>`, for keychain services, widget kinds and dispatch queue labels.
    static func scoped(_ suffix: String) -> String { "\(identifier).\(suffix)" }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        // An unexpanded `$(…)` means the Info.plist was not preprocessed with the build settings.
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
