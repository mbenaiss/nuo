import SwiftUI

struct NuoCommands: Commands {
    let bots: BotsStore
    @FocusedValue(\.navigator) private var navigator
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(newTitle) { navigator?.newItem(bots: bots.bots) }
                .keyboardShortcut("n")
                .disabled(navigator == nil)
            Button("New Reminder") { navigator?.showsQuickEntry = true }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(navigator == nil)
            Button("New Bot…") { navigator?.showsNewBot = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(navigator == nil)
            Button("New Project") { navigator?.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(navigator == nil)
            Button("New Area…") { navigator?.newArea() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                .disabled(navigator == nil)
            Divider()
            MeetingMenuItem()
            Divider()
            Button("Open in New Window") { openCurrentInWindow() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!canOpenInWindow)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { navigator?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(navigator == nil)
        }

        CommandGroup(before: .sidebar) {
            Button("Global Search…") { navigator?.showsPalette = true }
                .keyboardShortcut("k")
                .disabled(navigator == nil)
            Button("Refresh") {
                navigator?.refresh()
                Task { await bots.load() }
            }
                .keyboardShortcut("r")
                .disabled(navigator == nil)
            Divider()
        }

        CommandMenu("Go") {
            GoMenu(bots: bots, navigator: navigator)
            Divider()
            Button("Browser") { openWindow(id: MacWindow.browser) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            CalendarViewMenu(navigator: navigator)
        }
    }

    private var newTitle: String {
        switch navigator?.section {
        case .bots?: String(localized: "New Conversation")
        case .calendar?: String(localized: "New Event")
        case .schedules?: String(localized: "New Task")
        default: String(localized: "New Reminder")
        }
    }

    private var canOpenInWindow: Bool {
        guard let navigator else { return false }
        switch navigator.sidebar {
        case .bot?: return navigator.chat?.conversationId != nil
        case .docs?: return navigator.doc != nil
        default: return false
        }
    }

    private func openCurrentInWindow() {
        guard let navigator else { return }
        switch navigator.sidebar {
        case .bot?: if let chat = navigator.chat { openWindow(id: MacWindow.chat, value: chat) }
        case .docs?: if let doc = navigator.doc { openWindow(id: MacWindow.doc, value: doc) }
        default: break
        }
    }
}

private struct GoMenu: View {
    let bots: BotsStore
    let navigator: MacNavigator?

    /// ⌥⌘ + initial. Aujourd'hui takes ⌃⌘T: ⌥⌘T is AppKit's « Masquer la barre d'outils ».
    static func shortcut(_ list: ReminderSmartList) -> KeyboardShortcut {
        switch list {
        case .inbox: KeyboardShortcut("i", modifiers: [.command, .option])
        case .today: KeyboardShortcut("t", modifiers: [.command, .control])
        case .upcoming: KeyboardShortcut("u", modifiers: [.command, .option])
        case .anytime: KeyboardShortcut("a", modifiers: [.command, .option])
        case .someday: KeyboardShortcut("s", modifiers: [.command, .option])
        default: KeyboardShortcut("l", modifiers: [.command, .option])
        }
    }

    var body: some View {
        ForEach(MacSection.allCases) { section in
            Button(section.title) { navigator?.show(section, bots: bots.bots) }
                .keyboardShortcut(KeyEquivalent(Character(String(section.rawValue + 1))))
                .disabled(navigator == nil)
        }
        Divider()
        ForEach(ReminderSmartList.smartLists, id: \.self) { list in
            Button(list.title) { navigator?.sidebar = .reminders(list) }
                .keyboardShortcut(Self.shortcut(list))
                .disabled(navigator == nil)
        }
        Divider()
        ForEach(Array(bots.bots.prefix(9).enumerated()), id: \.element.id) { index, bot in
            BotMenuItem(bot: bot, index: index, navigator: navigator)
        }
    }
}

private struct BotMenuItem: View {
    let bot: Bot
    let index: Int
    let navigator: MacNavigator?

    var body: some View {
        let title = "\(bot.config?.emoji ?? "✨") \(bot.config?.name ?? String(localized: "Bot"))"
        Button(title) { navigator?.sidebar = .bot(bot.id) }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
            .disabled(navigator == nil)
    }
}

/// Présentation › calendar periods, enabled in the calendar only: ⌃1–⌃4, ⌘T, ⌘[ and ⌘].
private struct CalendarViewMenu: View {
    let navigator: MacNavigator?

    private var inCalendar: Bool { navigator?.sidebar == .calendar }

    var body: some View {
        Divider()
        ForEach(MacCalendarMode.allCases) { mode in
            Button(mode.label) { navigator?.calendarMode = mode }
                .keyboardShortcut(mode.shortcut, modifiers: .control)
                .disabled(!inCalendar)
        }
        Button("Today") { navigator?.goToToday() }
            .keyboardShortcut("t")
            .disabled(!inCalendar)
        Button("Previous Period") { navigator?.shiftCalendar(-1) }
            .keyboardShortcut("[")
            .disabled(!inCalendar)
        Button("Next Period") { navigator?.shiftCalendar(1) }
            .keyboardShortcut("]")
            .disabled(!inCalendar)
        Divider()
    }
}

/// ⇧⌘R from anywhere in the app: starts (or stops) the meeting transcription.
private struct MeetingMenuItem: View {
    @State private var recorder = MeetingRecorder.shared
    @State private var lock = AppLock.shared

    var body: some View {
        Button(recorder.isRecording ? String(localized: "Stop Meeting Transcription") : String(localized: "Transcribe a Meeting")) {
            if !recorder.isRecording, recorder.hasUnsavedWork {
                recorder.showWindow()
            } else {
                recorder.toggle()
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(lock.isLocked)
    }
}
