#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

typealias NuoActivityState = NuoActivityAttributes.ContentState

extension NuoActivityState {
    var phaseLabel: String {
        switch phase {
        case .thinking: String(localized: "Thinking…")
        case .working: currentTool.map { String(localized: "Working · \($0)") } ?? String(localized: "Working…")
        case .answering: String(localized: "Answering…")
        case .done: String(localized: "Reply ready")
        case .failed: String(localized: "Interrupted")
        case .cancelled: String(localized: "Stopped")
        }
    }

    var phaseColor: Color {
        switch phase {
        case .thinking: WPalette.accent2
        case .working, .answering: WPalette.accent
        case .done: WPalette.good
        case .failed: WPalette.bad
        case .cancelled: WPalette.text3
        }
    }

    var phaseSymbol: String {
        switch phase {
        case .thinking: "sparkles"
        case .working: "wrench.and.screwdriver.fill"
        case .answering: "text.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var stepsLabel: String? {
        guard steps > 0 else { return nil }
        return String(localized: "\(steps) steps")
    }

    var durationLabel: String {
        let seconds = max(1, Int((endedAt ?? .now).timeIntervalSince(startedAt).rounded()))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(String(format: "%02d", seconds % 60))"
    }
}

extension NuoActivityAttributes {
    var conversationLink: URL { NuoLink.conversation(id: conversationId, botId: botId).url }
}

/// Elapsed time while the turn runs, frozen duration once it ended.
struct WidgetActivityTimer: View {
    let state: NuoActivityState

    var body: some View {
        if state.phase.isRunning {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        } else {
            Text(state.durationLabel).monospacedDigit()
        }
    }
}

/// Three dots pulsing in turn; the Dynamic Island only animates symbol effects, not timers or custom animations.
struct WidgetActivityDots: View {
    var color: Color = WPalette.accent

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
    }
}

struct WidgetActivityLockView: View {
    let attributes: NuoActivityAttributes
    let state: NuoActivityState
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                WidgetBotTile(emoji: attributes.botEmoji, color: attributes.botColor, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.botName)
                        .font(.headline)
                        .foregroundStyle(WPalette.ink)
                    HStack(spacing: 5) {
                        Image(systemName: state.phaseSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state.phaseColor)
                        Text(state.phaseLabel)
                            .font(.subheadline.weight(state.phase == .done ? .semibold : .medium))
                            .foregroundStyle(state.phase == .done ? WPalette.good : WPalette.text2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    WidgetActivityTimer(state: state)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(WPalette.ink)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 68, alignment: .trailing)
                    if let steps = state.stepsLabel {
                        Text(steps)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WPalette.text3)
                    }
                }
            }
            if state.phase == .done, let answer = state.answer {
                Text(answer)
                    .font(.subheadline)
                    .foregroundStyle(WPalette.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(WPalette.good.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .leading) {
                        Capsule().fill(WPalette.good).frame(width: 3).padding(.vertical, 10)
                    }
            } else if let line = previewLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(state.phase == .failed ? WPalette.bad : WPalette.text2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(WPalette.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
    }

    private var previewLine: String? {
        if isStale && state.phase.isRunning { return String(localized: "Open Nuo to follow the reply.") }
        switch state.phase {
        case .cancelled: return String(localized: "You stopped the reply.")
        case .failed: return state.preview ?? String(localized: "The reply was interrupted.")
        default: return state.preview
        }
    }
}

struct WidgetIslandExpandedLeading: View {
    let attributes: NuoActivityAttributes

    var body: some View {
        HStack(spacing: 8) {
            WidgetBotTile(emoji: attributes.botEmoji, color: attributes.botColor, size: 36)
            Text(attributes.botName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.leading, 4)
    }
}

struct WidgetIslandExpandedTrailing: View {
    let state: NuoActivityState

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            WidgetActivityTimer(state: state)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 72, alignment: .trailing)
            if let steps = state.stepsLabel {
                Text(steps).font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.trailing, 4)
    }
}

struct WidgetIslandExpandedBottom: View {
    let attributes: NuoActivityAttributes
    let state: NuoActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.phaseSymbol).foregroundStyle(state.phaseColor)
                Text(state.phaseLabel)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if state.phase.isRunning { WidgetActivityDots(color: state.phaseColor) }
            }
            .font(.subheadline.weight(.semibold))
            if state.phase == .done, let answer = state.answer {
                Text(answer)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let preview = state.preview {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(state.phase == .failed ? WPalette.bad : .white.opacity(0.65))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if state.phase.isRunning {
                    Button(intent: WidgetStopTurnIntent(conversationId: attributes.conversationId)) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(WPalette.accent)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
                Link(destination: attributes.conversationLink) {
                    Label("Open", systemImage: "arrow.up.forward.app")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.16), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct WidgetIslandCompactTrailing: View {
    let state: NuoActivityState

    var body: some View {
        Group {
            switch state.phase {
            case .thinking, .answering:
                WidgetActivityDots(color: state.phaseColor)
            case .working:
                HStack(spacing: 3) {
                    Image(systemName: "gearshape.fill")
                        .symbolEffect(.rotate, options: .repeating)
                    Text("\(max(state.steps, 1))").monospacedDigit()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WPalette.accent)
            case .done, .failed, .cancelled:
                Image(systemName: state.phaseSymbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(state.phaseColor)
            }
        }
        .padding(.trailing, 2)
    }
}

struct WidgetIslandEmoji: View {
    let emoji: String
    var size: CGFloat = 16

    var body: some View {
        Text(emoji.isEmpty ? "✨" : emoji).font(.system(size: size))
    }
}
#endif
