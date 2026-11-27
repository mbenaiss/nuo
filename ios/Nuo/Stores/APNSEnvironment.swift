import Foundation

/// The APNs environment matching this build's signing, so the gateway targets the host that issued our tokens.
enum APNSEnvironment {
    static let current: String = resolve()

    private static func resolve() -> String {
        #if targetEnvironment(simulator)
        return "development"
        #else
        #if os(macOS)
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        let key = "com.apple.developer.aps-environment"
        #else
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let key = "aps-environment"
        #endif
        // App Store, TestFlight and Developer ID builds ship without a profile and always get production tokens.
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements[key] as? String
        else { return "production" }
        return value
        #endif
    }
}
