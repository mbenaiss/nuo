import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen and Dynamic Island of a session on the Muscu screen: the rest counts down, otherwise the set to do.
struct MuscuSessionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MuscuActivityAttributes.self) { context in
            MuscuActivityLockView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(WPalette.canvas)
                .activitySystemActionForegroundColor(WPalette.ink)
                .widgetURL(MuscuActivityAttributes.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.sessionName, systemImage: "dumbbell.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MuscuActivityCountdown(state: context.state)
                        .font(.title3.weight(.bold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.restUntil != nil ? String(localized: "Up next: \(context.state.step)") : context.state.step)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(WPalette.accent)
            } compactTrailing: {
                MuscuActivityCountdown(state: context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.restUntil != nil ? "timer" : "dumbbell.fill").foregroundStyle(WPalette.accent)
            }
            .widgetURL(MuscuActivityAttributes.link)
            .keylineTint(WPalette.accent)
        }
    }
}

/// The rest left, or the sets done when there is no rest.
private struct MuscuActivityCountdown: View {
    let state: MuscuActivityAttributes.ContentState

    var body: some View {
        let now = Date.now
        if let until = state.restUntil, until > now {
            Text(timerInterval: now...until, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(WPalette.accent)
        } else {
            Text(verbatim: "\(state.setsDone)/\(state.setsTotal)")
                .monospacedDigit()
        }
    }
}

private struct MuscuActivityLockView: View {
    let attributes: MuscuActivityAttributes
    let state: MuscuActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dumbbell.fill")
                .font(.title3)
                .foregroundStyle(WPalette.accent)
                .frame(width: 40, height: 40)
                .background(WPalette.chip, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(state.restUntil != nil ? String(localized: "Rest · \(attributes.sessionName)") : attributes.sessionName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WPalette.ink)
                    .lineLimit(1)
                Text(state.restUntil != nil ? String(localized: "Up next: \(state.step)") : state.step)
                    .font(.caption)
                    .foregroundStyle(WPalette.text2)
                    .lineLimit(1)
                Text("\(state.setsDone)/\(state.setsTotal) sets")
                    .font(.caption2)
                    .foregroundStyle(WPalette.text3)
            }
            Spacer(minLength: 8)
            MuscuActivityCountdown(state: state)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(WPalette.ink)
                .frame(maxWidth: 110, alignment: .trailing)
        }
        .padding(16)
    }
}

extension MuscuActivityAttributes {
    static let preview = MuscuActivityAttributes(sessionName: "Upper body", startedAt: .now.addingTimeInterval(-900))
}

#Preview("Rest", as: .content, using: MuscuActivityAttributes.preview) {
    MuscuSessionActivity()
} contentStates: {
    MuscuActivityAttributes.ContentState(step: "Block B · set 2/3", restUntil: .now.addingTimeInterval(62), restTotal: 75, setsDone: 4, setsTotal: 12)
    MuscuActivityAttributes.ContentState(step: "Block B · set 2/3", setsDone: 4, setsTotal: 12)
}
