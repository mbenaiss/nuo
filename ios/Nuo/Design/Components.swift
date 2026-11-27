import SwiftUI

enum Effort {
    static func label(_ value: String?) -> String {
        switch value?.lowercased() {
        case "minimal": String(localized: "effort.minimal", defaultValue: "Minimal")
        case "low": String(localized: "effort.low", defaultValue: "Fast")
        case "medium": String(localized: "effort.medium", defaultValue: "Medium")
        case "high": String(localized: "effort.high", defaultValue: "High")
        case "xhigh", "max": String(localized: "effort.max", defaultValue: "Max")
        case let other?: other.capitalized
        case nil: String(localized: "effort.default", defaultValue: "Default")
        }
    }

    static func symbol(_ value: String?) -> String {
        switch value?.lowercased() {
        case "minimal", "low": "gauge.with.dots.needle.0percent"
        case "medium": "gauge.with.dots.needle.50percent"
        case "high": "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}

extension AgentInfo {
    /// Readable agent name ("Claude Code" etc.) for menus.
    var displayName: String { name }
}

/// Short model name without the vendor prefix ("Claude Sonnet 5" → "Sonnet 5").
func shortModelName(_ name: String) -> String {
    for prefix in ["Claude ", "Gemini ", "Grok "] where name.hasPrefix(prefix) {
        return String(name.dropFirst(prefix.count))
    }
    return name
}

struct BotAvatar: View {
    let emoji: String
    let color: String
    var size: CGFloat = 44

    var body: some View {
        Text(emoji.isEmpty ? "✨" : emoji)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(tile, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }

    private var tile: Color {
        let base = Color(hexString: color) ?? Color.chip
        return base
    }
}

extension BotAvatar {
    init(config: BotConfig?, size: CGFloat = 44) {
        self.init(emoji: config?.emoji ?? "✨", color: config?.color ?? "#EFECE6", size: size)
    }
}

struct Badge: View {
    let text: String
    var dot: Color?
    var tint: Color = .text2
    var fill: Color = .chip

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(fill, in: Capsule())
    }
}

struct SectionHeader: View {
    private let title: Text

    init(title: LocalizedStringKey) { self.title = Text(title) }

    @_disfavoredOverload init<S: StringProtocol>(title: S) { self.title = Text(title) }

    var body: some View {
        title
            .textCase(.uppercase)
            .font(.caption.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(Color.text3)
    }
}

struct InkButtonStyle: ButtonStyle {
    var prominent = true
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(prominent ? Color.onInk : destructive ? Color.bad : Color.ink)
            .background(prominent ? Color.inkFill : Color.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Sectioned screen: an inset-grouped list on iPhone, a grouped form on the Mac, where a plain list
/// stretches the card-coloured rows edge to edge.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Round ink button: send, mic, stop.
struct RoundIconButton: View {
    let symbol: String
    var size: CGFloat = 44
    var fill: Color = .inkFill
    var foreground: Color = .onInk
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// The mic glyph from the mockups (filled dot in a ring).
struct VoiceGlyph: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.onInk, lineWidth: size * 0.12)
            Circle().fill(Color.onInk).padding(size * 0.28)
        }
        .frame(width: size, height: size)
    }
}

extension Date {
    var relativeLabel: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return String(localized: "just now") }
        if Calendar.current.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(self) { return String(localized: "yesterday") }
        if interval < 7 * 86400 { return formatted(.dateTime.weekday(.wide)) }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

func durationLabel(_ ms: Int) -> String {
    if ms < 950 {
        let tenths = Double(max(1, Int((Double(ms) / 100).rounded()))) / 10
        return "\(tenths.formatted(.number.precision(.fractionLength(1)))) s"
    }
    let seconds = max(1, Int((Double(ms) / 1000).rounded()))
    if seconds < 60 { return "\(seconds) s" }
    return "\(seconds / 60) min \(String(format: "%02d", seconds % 60))"
}
