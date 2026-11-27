#if DEBUG && canImport(ActivityKit) && os(iOS)
import SwiftUI
import UIKit

/// Renders the widgets and the Live Activity to PNGs for the design docs (`-renderWidgets` launch argument).
/// Output: the app's Documents/widget-renders folder.
@MainActor
enum WidgetSnapshotRenderer {
    private static let medium = CGSize(width: 364, height: 170)
    private static let large = CGSize(width: 364, height: 382)
    private static let small = CGSize(width: 170, height: 170)

    static func renderAll() {
        let snapshot = WidgetSnapshot.demo
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-renders")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func save<V: View>(_ name: String, _ view: V) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let data = renderer.uiImage?.pngData() else { return }
            try? data.write(to: folder.appendingPathComponent("\(name).png"))
        }

        save("40-widget-bots", sideBySide { _ in
            VStack(spacing: 22) {
                frame(medium, WPalette.canvas) { WidgetBotsView(snapshot: snapshot, large: false) }
                frame(large, WPalette.canvas) { WidgetBotsView(snapshot: snapshot, large: true) }
            }
        })
        save("41-widget-recents", sideBySide { _ in
            VStack(spacing: 22) {
                frame(medium, WPalette.card) { WidgetRecentsView(snapshot: snapshot, large: false) }
                frame(large, WPalette.card) { WidgetRecentsView(snapshot: snapshot, large: true) }
            }
        })
        save("42-widget-small", sideBySide { _ in
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    frame(small, WPalette.card) { WidgetBotSmallView(snapshot: snapshot, bot: snapshot.bot(id: "voyages")) }
                    frame(small, WPalette.card) { WidgetBotSmallView(snapshot: snapshot, bot: snapshot.bot(id: "coach")) }
                }
                HStack(spacing: 22) {
                    frame(small, WPalette.card) { WidgetBotSmallView(snapshot: snapshot, bot: snapshot.bot(id: "cobot")) }
                    frame(small, WPalette.card) { WidgetBotSmallView(snapshot: .signedOut, bot: nil) }
                }
            }
        })
        save("43-lockscreen", lockScreen {
            HStack(spacing: 12) {
                accessoryCircle { WidgetVoiceCircleView(bot: snapshot.bot(id: "voyages")) }
                accessoryCircle { WidgetVoiceCircleView(bot: snapshot.bot(id: "coach")) }
                WidgetLastReplyView(snapshot: snapshot, bot: snapshot.bot(id: "voyages"))
                    .foregroundStyle(.white)
                    .frame(width: 170, height: 72)
            }
            .environment(\.colorScheme, .dark)
        })

        let agenda = WidgetAgendaSnapshot.demo
        let now = Date.now
        save("126-widget-agenda", sideBySide { _ in
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    frame(small, WPalette.card) { WidgetAgendaNextView(snapshot: agenda, date: now) }
                    frame(small, WPalette.card) { WidgetAgendaNextView(snapshot: agenda, date: now.addingTimeInterval(4.6 * 3600)) }
                }
                frame(medium, WPalette.card) { WidgetAgendaListView(snapshot: agenda, date: now) }
            }
        })
        save("128-widget-agenda-large", sideBySide { _ in
            frame(large, WPalette.card) { WidgetAgendaDayView(snapshot: agenda, date: now) }
        })
        save("129-widget-month", sideBySide { _ in
            VStack(spacing: 22) {
                frame(medium, WPalette.card) { WidgetMonthView(family: .systemMedium, snapshot: agenda, date: now) }
                frame(large, WPalette.card) { WidgetMonthView(family: .systemLarge, snapshot: agenda, date: now) }
            }
        })
        let reminders = WidgetRemindersSnapshot.demo
        save("130-widget-reminders", sideBySide { _ in
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    frame(small, WPalette.card) { RemindersWidgetView(family: .systemSmall, entry: RemindersEntry(date: now, snapshot: reminders)) }
                    frame(small, WPalette.card) { RemindersWidgetView(family: .systemSmall, entry: RemindersEntry(date: now, snapshot: .init(status: .ready, items: [], fetchedAt: now))) }
                }
                frame(medium, WPalette.card) { RemindersWidgetView(family: .systemMedium, entry: RemindersEntry(date: now, snapshot: reminders)) }
                frame(large, WPalette.card) { RemindersWidgetView(family: .systemLarge, entry: RemindersEntry(date: now, snapshot: reminders)) }
            }
        })
        let noReminders = WidgetRemindersSnapshot(status: .ready, items: [], fetchedAt: now)
        let noEvents = WidgetAgendaSnapshot(status: .ready, items: [], fetchedAt: now)
        save("131-widget-mascot-states", sideBySide { _ in
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    frame(small, WPalette.card) { RemindersWidgetView(family: .systemSmall, entry: RemindersEntry(date: now, snapshot: noReminders)) }
                    frame(small, WPalette.card) { WidgetAgendaNextView(snapshot: noEvents, date: now) }
                }
                frame(medium, WPalette.card) { RemindersWidgetView(family: .systemMedium, entry: RemindersEntry(date: now, snapshot: noReminders)) }
                frame(medium, WPalette.card) { WidgetAgendaListView(snapshot: noEvents, date: now) }
                HStack(alignment: .top, spacing: 22) {
                    frame(small, WPalette.card) { WidgetSignedOutView(compact: true) }
                    Color.clear.frame(width: small.width, height: small.height)
                }
                frame(medium, WPalette.card) { WidgetSignedOutView() }
            }
        })
        save("132-mascot-states", sideBySide { _ in
            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    ForEach(MascotState.allCases, id: \.self) { state in MascotView(state: state, size: 96, animated: false) }
                }
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach([26, 44, 88, 104] as [CGFloat], id: \.self) { size in MascotView(state: .idle, size: size, animated: false) }
                }
            }
        })
        save("127-lockscreen-agenda", lockScreen {
            VStack(spacing: 12) {
                WidgetAgendaInlineView(snapshot: agenda, date: now)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 12) {
                    WidgetAgendaRectangularView(snapshot: agenda, date: now)
                        .foregroundStyle(.white)
                        .frame(width: 170, height: 72)
                    WidgetAgendaRectangularView(snapshot: agenda, date: now.addingTimeInterval(4.6 * 3600))
                        .foregroundStyle(.white)
                        .frame(width: 170, height: 72)
                }
            }
            .environment(\.colorScheme, .dark)
        })

        let attributes = NuoActivityAttributes(
            botId: "voyages", botName: "Travel", botEmoji: "✈️", botColor: "#E0EEFF", conversationId: "c-voyages-1")
        let working = NuoActivityState(phase: .working, steps: 2, currentTool: "flight_status", startedAt: now.addingTimeInterval(-9))
        let answering = NuoActivityState(
            phase: .answering, steps: 2, currentTool: "flight_status",
            preview: "Your flight TO8285 is on time, gate F32, boarding at 6:55 am.", startedAt: now.addingTimeInterval(-14))
        let done = NuoActivityState(
            phase: .done, steps: 2, preview: "Have a good flight! I'll let you know if the gate changes.",
            startedAt: now.addingTimeInterval(-18), endedAt: now)
        let thinking = NuoActivityState(phase: .thinking, steps: 0, startedAt: now.addingTimeInterval(-3))

        save("44-live-activity", lockScreen {
            VStack(spacing: 10) {
                banner(.light) { WidgetActivityLockView(attributes: attributes, state: working) }
                banner(.light) { WidgetActivityLockView(attributes: attributes, state: answering) }
                banner(.dark) { WidgetActivityLockView(attributes: attributes, state: done) }
            }
        })
        save("45-dynamic-island", islandSheet(attributes: attributes, states: [thinking, working, done], expanded: answering))

        let ready = NuoActivityState(
            phase: .done, steps: 2,
            answer: WidgetText.excerpt("**TO8285** is on time: departure **14:40** from Rome, gate **F32**, boarding at 13:55. Plan to arrive around 12:40, the security line is long on Mondays.\n::flight {\"flight\":\"TO8285\"}"),
            startedAt: now.addingTimeInterval(-18), endedAt: now)
        let failed = NuoActivityState(
            phase: .failed, steps: 1, preview: "The agent is no longer responding (timed out).", startedAt: now.addingTimeInterval(-40), endedAt: now)
        let stopped = NuoActivityState(phase: .cancelled, steps: 1, startedAt: now.addingTimeInterval(-6), endedAt: now)
        save("73-live-activity-done", HStack(alignment: .top, spacing: 0) {
            lockScreen {
                VStack(spacing: 10) {
                    banner(.light) { WidgetActivityLockView(attributes: attributes, state: ready) }
                    banner(.dark) { WidgetActivityLockView(attributes: attributes, state: ready) }
                    banner(.light) { WidgetActivityLockView(attributes: attributes, state: failed) }
                    banner(.light) { WidgetActivityLockView(attributes: attributes, state: stopped) }
                }
            }
            islandSheet(attributes: attributes, states: [ready], expanded: ready)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(WPalette.rgb(0xFBD9C2))
        }.fixedSize())
    }

    // MARK: - Scene helpers

    private static func frame<V: View>(_ size: CGSize, _ background: Color, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private static func sideBySide<V: View>(@ViewBuilder _ content: @escaping (ColorScheme) -> V) -> some View {
        HStack(spacing: 0) {
            content(.light)
                .padding(36)
                .frame(maxHeight: .infinity)
                .background(LinearGradient(colors: [WPalette.rgb(0xFBD9C2), WPalette.rgb(0xF4EEE6), WPalette.rgb(0xDCE7F7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, .light)
            content(.dark)
                .padding(36)
                .frame(maxHeight: .infinity)
                .background(LinearGradient(colors: [WPalette.rgb(0x2B1A14), WPalette.rgb(0x111116), WPalette.rgb(0x15192A)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, .dark)
        }
        .fixedSize()
    }

    private static let wallpaper = LinearGradient(
        colors: [WPalette.rgb(0x3A2A6B), WPalette.rgb(0xC2533A), WPalette.rgb(0xF2A65A)],
        startPoint: .top, endPoint: .bottom)

    private static func lockScreen<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0) {
            Text("Friday, October 17")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 70)
            Text("9:41")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            content()
                .padding(.top, 18)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
        .frame(width: 402)
        .frame(minHeight: 520)
        .background(wallpaper)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func accessoryCircle<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(.white.opacity(0.18), in: Circle())
            .clipShape(Circle())
    }

    private static func banner<V: View>(_ scheme: ColorScheme, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .background(WPalette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, scheme)
    }

    private static func islandSheet(attributes: NuoActivityAttributes, states: [NuoActivityState], expanded: NuoActivityState) -> some View {
        VStack(spacing: 26) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                HStack(spacing: 0) {
                    WidgetIslandEmoji(emoji: attributes.botEmoji)
                        .frame(width: 44, alignment: .leading)
                    Spacer()
                    WidgetIslandCompactTrailing(state: state)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(width: 250, height: 37)
                .background(.black, in: Capsule())
            }
            HStack(spacing: 8) {
                Capsule().fill(.black).frame(width: 190, height: 37)
                WidgetIslandEmoji(emoji: attributes.botEmoji, size: 15)
                    .frame(width: 37, height: 37)
                    .background(.black, in: Circle())
            }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    WidgetIslandExpandedLeading(attributes: attributes)
                    Spacer()
                    WidgetIslandExpandedTrailing(state: expanded)
                }
                WidgetIslandExpandedBottom(attributes: attributes, state: expanded)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(width: 372)
            .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .padding(.vertical, 40)
        .frame(width: 440)
        .background(LinearGradient(colors: [WPalette.rgb(0xF6F4F0), WPalette.rgb(0xFBD9C2)], startPoint: .top, endPoint: .bottom))
    }
}
#endif
