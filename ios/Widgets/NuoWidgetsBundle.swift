import SwiftUI
import WidgetKit

@main
struct NuoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BotsWidget()
        RecentsWidget()
        BotWidget()
        VoiceAccessoryWidget()
        LastReplyAccessoryWidget()
        AgendaWidget()
        AgendaAccessoryWidget()
        MonthWidget()
        RemindersWidget()
        RemindersAccessoryWidget()
        NuoBotActivity()
    }
}
