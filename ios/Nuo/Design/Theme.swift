import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Parses `#RRGGBB` (bot colors come from the gateway as hex strings).
    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color.dynamic { isDark in
            let hex = isDark ? dark : light
            return PlatformColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }
}

extension Color {
    static let canvas = Color.adaptive(light: 0xF6F4F0, dark: 0x0C0C10)
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x18181D)
    static let ink = Color.adaptive(light: 0x16161A, dark: 0xF4F2EE)
    static let text2 = Color.adaptive(light: 0x6E6C72, dark: 0x9C9AA2)
    static let text3 = Color.adaptive(light: 0xA3A1A8, dark: 0x6A6870)
    static let line = Color.adaptive(light: 0xE8E5DF, dark: 0x2A2A31)
    static let chip = Color.adaptive(light: 0xEFECE6, dark: 0x232329)
    static let accent = Color(hex: 0xFF6A2B)
    static let accent2 = Color(hex: 0xFFB36B)
    static let accentSoft = Color.adaptive(light: 0xFFE5D3, dark: 0x3A2318)
    static let accentInk = Color.adaptive(light: 0xB2410E, dark: 0xFFA06E)
    static let good = Color.adaptive(light: 0x1F9D57, dark: 0x34C17A)
    static let bad = Color(hex: 0xE5484D)
    /// Solid ink fill (send/mic buttons, user bubble, primary button) and its foreground.
    static let inkFill = Color.adaptive(light: 0x16161A, dark: 0xF4F2EE)
    static let onInk = Color.adaptive(light: 0xFFFFFF, dark: 0x16161A)
    static let userBubble = Color.adaptive(light: 0x16161A, dark: 0x2C2C33)
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = CardMetrics.padding
    var radius: CGFloat = Radius.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = CardMetrics.padding, radius: CGFloat = Radius.lg) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }

    /// Floating glass surface used by the composer and the home dock. Interactive glass takes the touches over its
    /// whole area, including those meant for a menu drawn on top of it.
    func glassSurface(radius: CGFloat, interactive: Bool = true) -> some View {
        self
            .glassEffect(.regular.tint(Color.card.opacity(0.55)).interactive(interactive), in: .rect(cornerRadius: radius))
            .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
