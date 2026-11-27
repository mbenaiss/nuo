import SwiftUI
import UIKit

/// Colors of the main app's design system (Nuo/Design/Theme.swift), which this target does not compile.
enum Palette {
    static let canvas = adaptive(light: 0xF6F4F0, dark: 0x0C0C10)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x18181D)
    static let ink = adaptive(light: 0x16161A, dark: 0xF4F2EE)
    static let text2 = adaptive(light: 0x6E6C72, dark: 0x9C9AA2)
    static let text3 = adaptive(light: 0xA3A1A8, dark: 0x6A6870)
    static let line = adaptive(light: 0xE8E5DF, dark: 0x2A2A31)
    static let chip = adaptive(light: 0xEFECE6, dark: 0x232329)
    static let accent = rgb(0xFF6A2B)
    static let accentSoft = adaptive(light: 0xFFE5D3, dark: 0x3A2318)
    static let accentInk = adaptive(light: 0xB2410E, dark: 0xFFA06E)
    static let good = adaptive(light: 0x1F9D57, dark: 0x34C17A)
    static let bad = rgb(0xE5484D)
    static let inkFill = adaptive(light: 0x16161A, dark: 0xF4F2EE)
    static let onInk = adaptive(light: 0xFFFFFF, dark: 0x16161A)
    /// Text on a bot's pastel color, which stays light in dark mode.
    static let onBot = rgb(0x16161A)

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func hex(_ string: String?) -> Color? {
        guard var text = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return rgb(value)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    func shareCard(radius: CGFloat = 18) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
    }
}
