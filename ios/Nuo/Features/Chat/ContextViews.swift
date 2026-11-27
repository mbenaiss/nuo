import SwiftUI

enum TokenFormat {
    /// "84 k", "1,2 M", "950".
    static func short(_ tokens: Int) -> String {
        let locale = Locale.current
        if tokens >= 1_000_000 {
            return (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " M"
        }
        if tokens >= 1_000 {
            let k = Double(tokens) / 1_000
            return k.formatted(.number.precision(.fractionLength(0...(k < 10 ? 1 : 0))).locale(locale)) + " k"
        }
        return "\(tokens)"
    }
}

extension ContextUsage {
    /// 0...1, nil when the window size is unknown.
    var fraction: Double? {
        guard let maxTokens, maxTokens > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(maxTokens)))
    }
}

enum ContextLevel {
    case unknown, low, medium, high

    init(_ context: ContextUsage?) {
        guard let fraction = context?.fraction else { self = .unknown; return }
        self = fraction > 0.85 ? .high : fraction >= 0.6 ? .medium : .low
    }

    var color: Color {
        switch self {
        case .unknown, .low: Color.text2
        case .medium: Color(hex: 0xF29A1F)
        case .high: Color.bad
        }
    }

    var ringColor: Color {
        switch self {
        case .unknown: Color.text3
        case .low: Color.ink.opacity(0.55)
        case .medium, .high: color
        }
    }
}

extension BotCommand {
    static let compactName = "compact"

    /// Built into every bot by the gateway (docs/protocol.md, "Context and compaction").
    static let compact = BotCommand(
        name: compactName, description: String(localized: "Compact the conversation to free up context"),
        action: Action(type: "prompt"))
}

extension Message {
    /// A message that is only a `::notice {…}` line (e.g. a persisted compaction).
    var notice: NoticePayload? {
        guard role == .assistant, text.hasPrefix("::notice") else { return nil }
        let blocks = ResponseBlockParser.parse(text)
        guard blocks.count == 1, case let .notice(payload) = blocks[0] else { return nil }
        return payload
    }

    static func noticeLine(kind: String, text: String, beforeTokens: Int?, afterTokens: Int?) -> String {
        var json: [String: Any] = ["kind": kind, "text": text]
        if let beforeTokens { json["beforeTokens"] = beforeTokens }
        if let afterTokens { json["afterTokens"] = afterTokens }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        return "::notice " + (String(data: data, encoding: .utf8) ?? "{}")
    }
}

/// Bot avatar circled by the context gauge, with the percentage in a badge: the chat header has no room for
/// another toolbar item (the bar folds extra items into its overflow menu).
struct ContextAvatar: View {
    let config: BotConfig?
    let context: ContextUsage?

    var body: some View {
        let level = ContextLevel(context)
        ZStack {
            Circle().stroke(Color.line, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: context?.fraction ?? 0)
                .stroke(level.ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            BotAvatar(config: config, size: 30)
                .clipShape(Circle())
        }
        .frame(width: 40, height: 40)
        .overlay(alignment: .bottom) {
            if context?.fraction != nil {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(level == .low || level == .unknown ? Color.ink : .white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badgeFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.canvas, lineWidth: 1.5))
                    .fixedSize()
                    .offset(y: 7)
                    .contentTransition(.numericText())
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: context?.usedTokens)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context?.fraction == nil ? String(localized: "Context unknown") : String(localized: "Context used: \(label)"))
    }

    private var badgeFill: Color {
        switch ContextLevel(context) {
        case .unknown, .low: Color.chip
        case .medium, .high: ContextLevel(context).color
        }
    }

    private var label: String {
        guard let fraction = context?.fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Small ring with the percentage of the context window in use.
struct ContextGauge: View {
    let context: ContextUsage?
    var compact = false

    var body: some View {
        let level = ContextLevel(context)
        let size: CGFloat = compact ? 14 : 22
        HStack(spacing: compact ? 4 : 5) {
            ZStack {
                Circle().stroke(Color.line, lineWidth: compact ? 2 : 3)
                Circle()
                    .trim(from: 0, to: context?.fraction ?? 0)
                    .stroke(level.ringColor, style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            Text(label)
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(level == .low ? Color.text2 : level.color)
                .contentTransition(.numericText())
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: context?.usedTokens)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context?.fraction == nil ? String(localized: "Context unknown") : String(localized: "Context used: \(label)"))
    }

    private var label: String {
        guard let fraction = context?.fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

struct ContextSheet: View {
    let context: ContextUsage?
    let modelLabel: String
    let isRunning: Bool
    let onCompact: () -> Void

    var body: some View {
        let level = ContextLevel(context)
        // Scrolls so the title is never clipped under the grabber at the medium detent (small iPhones).
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context").font(.title2.bold()).foregroundStyle(Color.ink)
                    Spacer()
                    Text(percentLabel)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(level == .unknown || level == .low ? Color.ink : level.color)
                }

                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.chip)
                            Capsule()
                                .fill(level == .low ? Color.ink : level.color)
                                .frame(width: max(8, geo.size.width * (context?.fraction ?? 0)))
                                .opacity(context?.fraction == nil ? 0 : 1)
                        }
                    }
                    .frame(height: 10)
                    Text(tokensLabel)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.text2)
                }

                VStack(spacing: 0) {
                    row("Model", modelLabel)
                    Divider().overlay(Color.line)
                    row("Compactions", "\(context?.compactions ?? 0)")
                    if let updatedAt = context?.updatedAt {
                        Divider().overlay(Color.line)
                        row("Updated", updatedAt.formatted(.relative(presentation: .named).locale(.current)))
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))

                Text("Context is the agent's working memory for this conversation. As it fills up, replies slow down and the agent forgets the beginning. Compacting replaces the history with a dense summary: the conversation carries on, with much more room.")
                    .font(.footnote)
                    .foregroundStyle(Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button(action: onCompact) {
                Label("Compact the conversation", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(InkButtonStyle(prominent: true))
            .disabled(isRunning)
            .opacity(isRunning ? 0.5 : 1)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xs)
            .background(Color.canvas)
        }
        .background(Color.canvas)
    }

    private var percentLabel: String {
        guard let fraction = context?.fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private var tokensLabel: String {
        guard let context else { return String(localized: "No measurement yet for this conversation.") }
        let used = TokenFormat.short(context.usedTokens)
        guard let max = context.maxTokens else { return String(localized: "\(used) tokens used · window unknown") }
        return "\(used) / \(TokenFormat.short(max)) tokens"
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.text2)
            Spacer()
            Text(value).foregroundStyle(Color.ink).monospacedDigit().lineLimit(1)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
    }
}

/// Centered divider chip for system notices ("Conversation compactée · 120 k → 8 k tokens").
struct NoticeChip: View {
    let payload: NoticePayload
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            line
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accent)
                    .symbolEffect(.bounce, value: appeared)
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.text2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.chip, in: Capsule())
            .layoutPriority(1)
            line
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle().fill(Color.line).frame(height: 1).frame(maxWidth: .infinity)
    }

    private var symbol: String {
        switch payload.kind {
        case "compacted": "arrow.down.right.and.arrow.up.left"
        case "switched": "arrow.triangle.2.circlepath"
        default: "info.circle"
        }
    }

    private var label: String {
        let title = payload.text.isEmpty ? (payload.kind == "compacted" ? String(localized: "Conversation compacted") : String(localized: "Info")) : payload.text
        guard let before = payload.beforeTokens, let after = payload.afterTokens else { return title }
        return "\(title) · \(TokenFormat.short(before)) → \(TokenFormat.short(after)) tokens"
    }
}

/// Shown while a `/compact` runs.
struct CompactingChip: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Compacting…").font(.footnote.weight(.medium)).foregroundStyle(Color.text2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.chip, in: Capsule())
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
