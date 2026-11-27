import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static let accent = Color(hex: 0xFF6A2B)
    static let accent2 = Color(hex: 0xFFB36B)
    static let surface = Color(hex: 0x1C1C21)
    static let surface2 = Color(hex: 0x2A2A31)
    static let userBubble = Color(hex: 0x34343C)
    static let good = Color(hex: 0x34C17A)
}

/// Three dots breathing while a bot works.
struct PulsingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accent)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase ? 1 : 0.5)
                    .opacity(phase ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.18), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

enum WorkSummary {
    static func label(durationMs: Int?, steps: Int) -> String? {
        guard durationMs != nil || steps > 0 else { return nil }
        var parts: [String] = []
        if let durationMs {
            let seconds = max(1, durationMs / 1000)
            parts.append(seconds < 60 ? String(localized: "Worked \(seconds) s") : String(localized: "Worked \(seconds / 60) min \(seconds % 60) s"))
        }
        if steps > 0 { parts.append(String(localized: "\(steps) steps")) }
        return parts.joined(separator: " · ")
    }
}
