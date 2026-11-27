#if NUO_WATCH_WIDGETS
import SwiftUI
import WidgetKit

// Compiled only in the watch widget extension (SWIFT_ACTIVE_COMPILATION_CONDITIONS = NUO_WATCH_WIDGETS),
// since the watch app target already has its own `@main`.
@main
struct NuoWatchWidgetsEntry: WidgetBundle {
    var body: some Widget {
        LastReplyComplication()
        AgendaComplication()
        RemindersComplication()
        TalkComplication()
        QuickActionsCard()
        TalkControl()
    }
}
#endif
