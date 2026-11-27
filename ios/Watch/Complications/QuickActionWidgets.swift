import AppIntents
import SwiftUI
import WidgetKit

// The watch's one action in one gesture, without opening the app first: a complication on the face, a card of the
// Smart Stack, a button of the Control Center (watchOS 26) and Siri. Compiled in the app and in the widget extension;
// the intent opens the app, where it runs.

enum QuickActionLink {
    static let capture = URL(string: "nuo://watch/ask")!
}

/// Opens the microphone of the watch's button: a request to the general bot under a minute, a recorded meeting past
/// it. The capture has to begin in front: watchOS keeps it going in the background only when it started there.
struct TalkToNuoIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Nuo"
    static let description = IntentDescription("Opens the microphone: your request goes to the General bot; past one minute, it's a recorded meeting.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !NUO_WATCH_WIDGETS
        VoiceRecorder.shared.startRequested = true
        #endif
        return .result()
    }
}

#if !NUO_WATCH_WIDGETS
struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToNuoIntent(),
            phrases: ["Tell \(.applicationName)", "Talk to \(.applicationName)", "Ask \(.applicationName)",
                      "Record the meeting with \(.applicationName)", "Record with \(.applicationName)"],
            shortTitle: "Talk to Nuo",
            systemImageName: "mic.fill")
    }
}
#endif

// MARK: - Complications and Smart Stack

struct QuickActionEntry: TimelineEntry {
    let date: Date
}

struct QuickActionProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionEntry { QuickActionEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (QuickActionEntry) -> Void) { completion(QuickActionEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionEntry>) -> Void) {
        completion(Timeline(entries: [QuickActionEntry(date: .now)], policy: .never))
    }
}

struct TalkComplication: Widget {
    nonisolated static let kind = AppIdentity.local(.watchTalkKind)

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickActionProvider()) { _ in
            QuickActionComplicationView(symbol: "mic.fill", title: "Nuo", tint: Color(red: 1, green: 0.42, blue: 0.17))
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(QuickActionLink.capture)
        }
        .configurationDisplayName("Nuo")
        .description("Opens the microphone: a task, an event, a question, or a meeting past one minute.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/// The Smart Stack card: the same microphone, with room to say what it does.
struct QuickActionsCard: Widget {
    nonisolated static let kind = AppIdentity.local(.watchQuickKind)

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickActionProvider()) { _ in
            QuickActionsCardView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Nuo")
        .description("Talk to Nuo; past one minute, the meeting is recorded.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct QuickActionComplicationView: View {
    let symbol: String
    let title: String
    let tint: Color
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(title, systemImage: symbol)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .widgetAccentable()
                .widgetLabel { Text(title) }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .widgetAccentable()
            }
            .accessibilityLabel(title)
        }
    }
}

struct QuickActionsCardView: View {
    var body: some View {
        Button(intent: TalkToNuoIntent()) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.17))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Talk to Nuo")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Over a minute: meeting")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Control Center

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AppIdentity.local(.watchTalkControlKind)) {
            ControlWidgetButton(action: TalkToNuoIntent()) {
                Label("Talk to Nuo", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to Nuo")
        .description("Opens Nuo's microphone: a request, or a meeting past one minute.")
    }
}
