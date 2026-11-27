import ImageIO
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Decodes off the main thread into a bitmap ready to draw, optionally downsampled to `maxPixel`.
    nonisolated static func decoded(_ data: Data, maxPixel: CGFloat? = nil) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

extension Color {
    init(platformColor: PlatformColor) {
        #if canImport(UIKit)
        self.init(uiColor: platformColor)
        #else
        self.init(nsColor: platformColor)
        #endif
    }

    /// Resolves a light or dark value from the current appearance.
    static func dynamic(_ provider: @escaping @Sendable (_ isDark: Bool) -> PlatformColor) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { provider($0.userInterfaceStyle == .dark) })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            provider(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
        #endif
    }
}

enum PlatformDevice {
    @MainActor static var name: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

enum PlatformApp {
    @MainActor static var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.isActive
        #endif
    }

    @MainActor static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    @MainActor static func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    @MainActor static func unregisterForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.unregisterForRemoteNotifications()
        #else
        NSApplication.shared.unregisterForRemoteNotifications()
        #endif
    }
}

enum Haptics {
    #if canImport(UIKit)
    // Kept alive rather than made per call: the Taptic Engine takes a moment to wake, and a generator that is
    // created and fired in the same breath drops its first impulse.
    @MainActor private static let light = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let medium = UIImpactFeedbackGenerator(style: .medium)

    /// Wakes the engine when a feedback is coming but not yet due, so it lands instead of being swallowed.
    @MainActor static func prepare() { medium.prepare() }
    @MainActor static func tap() { light.impactOccurred() }
    @MainActor static func send() { medium.impactOccurred() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    #else
    // Only Force Touch trackpads give feedback; a send or a pick needs none on a Mac.
    @MainActor static func prepare() {}
    @MainActor static func tap() {}
    @MainActor static func send() {}
    @MainActor static func success() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    @MainActor static func error() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
    @MainActor static func selection() {}
    #endif
}

enum PlatformPasteboard {
    @MainActor static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension UNAuthorizationStatus {
    var allowsDelivery: Bool {
        #if os(iOS)
        self == .authorized || self == .provisional || self == .ephemeral
        #else
        self == .authorized || self == .provisional
        #endif
    }
}
