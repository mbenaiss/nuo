#if DEBUG && !NUO_WATCH_WIDGETS
import SwiftUI
import WidgetKit

/// Renders the circular complications to PNGs (`-renderComplications`), in full color and as a tinted face would
/// flatten them. Output: the watch app's Documents/complication-renders folder.
@MainActor
enum ComplicationSnapshotRenderer {
    static func renderIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-renderComplications") else { return }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("complication-renders")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date.now
        let agenda = AgendaEntry(date: now, snapshot: .demo)
        let noEvents = AgendaEntry(date: now, snapshot: WidgetAgendaSnapshot(status: .ready, items: [], fetchedAt: now))
        let reminders = RemindersEntry(date: now, snapshot: .demo)
        let allDone = RemindersEntry(date: now, snapshot: WidgetRemindersSnapshot(status: .ready, items: [], fetchedAt: now))

        let sheet = VStack(spacing: 14) {
            ForEach([false, true], id: \.self) { tinted in
                HStack(spacing: 14) {
                    cell(tinted) { AgendaCircularView(entry: noEvents) }
                    cell(tinted) { RemindersCircularView(entry: allDone) }
                    cell(tinted) { AgendaCircularView(entry: agenda) }
                    cell(tinted) { RemindersCircularView(entry: reminders) }
                }
            }
        }
        .padding(16)
        .background(.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else { return }
        try? data.write(to: folder.appendingPathComponent("circular.png"))
    }

    /// Tinted faces draw everything in one hue: grayscale is a fair stand-in to judge contrast and shapes.
    private static func cell<V: View>(_ tinted: Bool, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: 50, height: 50)
            .background(Circle().fill(Color.white.opacity(0.14)))
            .clipShape(Circle())
            .grayscale(tinted ? 1 : 0)
            .brightness(tinted ? 0.15 : 0)
    }
}
#endif
