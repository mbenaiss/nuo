import ActivityKit
import SwiftUI
import WidgetKit

struct NuoBotActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NuoActivityAttributes.self) { context in
            WidgetActivityLockView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(WPalette.canvas)
                .activitySystemActionForegroundColor(WPalette.ink)
                .widgetURL(context.attributes.conversationLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetIslandExpandedLeading(attributes: context.attributes)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WidgetIslandExpandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WidgetIslandExpandedBottom(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                WidgetIslandEmoji(emoji: context.attributes.botEmoji)
            } compactTrailing: {
                WidgetIslandCompactTrailing(state: context.state)
            } minimal: {
                WidgetIslandEmoji(emoji: context.attributes.botEmoji, size: 15)
            }
            .widgetURL(context.attributes.conversationLink)
            .keylineTint(context.state.phaseColor)
        }
    }
}

extension NuoActivityAttributes {
    static let preview = NuoActivityAttributes(
        botId: "voyages", botName: "Travel", botEmoji: "✈️", botColor: "#E0EEFF", conversationId: "c-voyages-1")
}

extension NuoActivityAttributes.ContentState {
    static let previewThinking = Self(phase: .thinking, steps: 0, startedAt: .now.addingTimeInterval(-4))
    static let previewWorking = Self(phase: .working, steps: 2, currentTool: "flight_status", startedAt: .now.addingTimeInterval(-9))
    static let previewAnswering = Self(
        phase: .answering, steps: 2, currentTool: "flight_status",
        preview: "Your flight TO8285 is on time, gate F32, boarding at 6:55 am.", startedAt: .now.addingTimeInterval(-14))
    static let previewDone = Self(
        phase: .done, steps: 2, preview: "Have a good flight! I'll let you know if the gate changes.",
        startedAt: .now.addingTimeInterval(-18), endedAt: .now)
}

#Preview("Live Activity", as: .content, using: NuoActivityAttributes.preview) {
    NuoBotActivity()
} contentStates: {
    NuoActivityAttributes.ContentState.previewThinking
    NuoActivityAttributes.ContentState.previewWorking
    NuoActivityAttributes.ContentState.previewAnswering
    NuoActivityAttributes.ContentState.previewDone
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: NuoActivityAttributes.preview) {
    NuoBotActivity()
} contentStates: {
    NuoActivityAttributes.ContentState.previewAnswering
}

#Preview("Compact", as: .dynamicIsland(.compact), using: NuoActivityAttributes.preview) {
    NuoBotActivity()
} contentStates: {
    NuoActivityAttributes.ContentState.previewWorking
}
