import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @State private var reminders = RemindersStore.shared
    @State private var meeting = MeetingRecorder.shared
    @State private var windows = MacWindowRequests.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let due = reminders.count(.today) + reminders.count(.overdue)
        HStack(spacing: 3) {
            if meeting.isRecording {
                Image(systemName: "waveform")
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
            }
            if due > 0 { Text("\(due)").monospacedDigit() }
        }
        // The menu bar label lives as long as the app: it opens the meeting window even with every window closed.
        .onChange(of: meeting.windowRequest) { _, _ in
            openWindow(id: MacWindow.meeting)
            NSApp.activate()
        }
        // A notification tapped with the main window closed must still show its screen.
        .onChange(of: windows.main) { _, _ in
            openWindow(id: MacWindow.main)
            NSApp.activate()
        }
        .onChange(of: windows.settings) { _, _ in
            openSettings()
            NSApp.activate()
        }
        .onChange(of: windows.browser) { _, _ in
            openWindow(id: MacWindow.browser)
            NSApp.activate()
        }
    }
}

/// Menu bar extra: ask a bot without opening the window, and tick off today's reminders.
struct MenuBarPanel: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(\.openWindow) private var openWindow
    @State private var reminders = RemindersStore.shared
    @State private var botId: String?
    @State private var prompt = ""
    @State private var answer = ""
    @State private var conversationId: String?
    @State private var running = false
    /// The panel closed before the answer ended: it goes on in the conversation and arrives as a notification.
    @State private var detached = false
    @State private var failure: String?
    @State private var lock = AppLock.shared
    @State private var listener: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var bot: Bot? { botId.flatMap { bots.bot(id: $0) } ?? bots.recentBots.first ?? bots.bots.first }
    private var today: [Reminder] { reminders.items(.overdue) + reminders.items(.today) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Spacing.xs) {
                MascotView(state: session.phase != .ready ? .sleep : running ? .think : .idle, size: MascotMetrics.menuBar)
                Text("Nuo").font(.headline)
            }
            if lock.isLocked {
                Text("Nuo is locked.").foregroundStyle(.secondary)
                HStack {
                    Button("Unlock") { Task { await lock.unlock() } }
                        .disabled(lock.isUnlocking)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.borderless)
                }
            } else if session.phase != .ready {
                Text("Nuo isn't paired yet.").foregroundStyle(.secondary)
                Button("Open Nuo") { openMain() }
            } else {
                askSection
                Divider()
                MeetingStartCard(compact: true)
                Divider()
                MenuBarAgenda(openMain: openMain)
                Divider()
                remindersSection
                Divider()
                HStack {
                    Button("Open Nuo") { openMain() }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .padding(14)
        .frame(width: 360)
        .hiddenFromScreenSharing(MeetingRecorder.shared.isRecording)
        .onAppear { focused = true }
        .onDisappear(perform: detach)
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(bots.bots) { candidate in
                        Button("\(candidate.config?.emoji ?? "✨") \(candidate.config?.name ?? String(localized: "Bot"))") {
                            botId = candidate.id
                            reset()
                        }
                    }
                } label: {
                    // A borderless menu keeps only the first view of a stacked label, which dropped the bot name.
                    Text(verbatim: "\(bot?.config?.emoji ?? "✨")  \(bot?.config?.name ?? String(localized: "Bot"))").font(.callout.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                TextField("Ask \(bot?.config?.name ?? String(localized: "your bot"))…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(running)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Color.accent.opacity(0.6) : Color.line))
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accent)
                    .disabled(running || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !answer.isEmpty || failure != nil || detached {
                if !answer.isEmpty || failure != nil {
                    ScrollView {
                        Text(failure ?? ResponseBlockParser.plainText(answer))
                            .font(.callout)
                            .foregroundStyle(failure == nil ? Color.ink : Color.bad)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(10)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if detached {
                    Text("The rest of the reply will arrive as a notification.").font(.caption).foregroundStyle(.secondary)
                }
                if let conversationId, let bot {
                    Button("Continue in Nuo") {
                        AppRouter.shared.openNotification(conversationId: conversationId, botId: bot.id)
                        openMain()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if today.isEmpty {
                Text("Nothing for today.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(today.prefix(8)) { reminder in
                    ReminderRow(reminder: reminder, segment: .today, completing: reminders.completing.contains(reminder.id)) {
                        reminders.toggleDone(reminder)
                    }
                }
                if today.count > 8 {
                    Text("and \(today.count - 8) more…").font(.caption).foregroundStyle(.secondary)
                }
            }
            InlineReminderEntry()
        }
    }

    private func reset() {
        listener?.cancel()
        listener = nil
        answer = ""
        failure = nil
        conversationId = nil
        running = false
        detached = false
    }

    /// A closed panel stops following the answer; left running, the next opening would spin forever.
    private func detach() {
        guard running else { return }
        listener?.cancel()
        listener = nil
        running = false
        detached = conversationId != nil
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bot, !text.isEmpty, !running else { return }
        reset()
        running = true
        prompt = ""
        Task {
            do {
                let conversation = try await session.api.createConversation(botId: bot.id, useDraft: false)
                conversationId = conversation.id
                if running { listen(conversation.id) } else { detached = true }
                AnswerNotifier.shared.remember(conversationId: conversation.id, botId: bot.id)
                try await session.transport.send(.prompt(conversationId: conversation.id, text: text))
                bots.touch(botId: bot.id, preview: text)
            } catch {
                failure = error.localizedDescription
                running = false
            }
        }
    }

    private func listen(_ id: String) {
        let events = session.transport.events()
        listener = Task {
            for await event in events {
                switch event {
                case let .messageDelta(conversationId, _, text) where conversationId == id:
                    answer += text
                case let .messageEnd(conversationId, _, _, _, stopReason, _, _, _) where conversationId == id:
                    running = false
                    if stopReason == .error, answer.isEmpty { failure = String(localized: "The reply was interrupted.") }
                    return
                case let .error(conversationId, message) where conversationId == id:
                    failure = message
                    running = false
                    return
                default:
                    break
                }
            }
        }
    }

    private func openMain() {
        openWindow(id: MacWindow.main)
        NSApp.activate()
    }
}

/// Today's next events with « Rejoindre », and a one-line natural-language entry.
private struct MenuBarAgenda: View {
    let openMain: () -> Void
    @State private var store = CalendarStore.shared
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?

    private var parsed: ParsedEvent { EventParser.parse(text, calendars: store.calendars) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            // Reminders already have their own list just below.
            let items = store.upcoming(limit: 12, from: context.date)
                .filter { $0.kind != .reminder && (AgendaCalendar.current.isDateInToday($0.start) || $0.start <= context.date) }
                .prefix(4)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Agenda").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if items.isEmpty {
                    Text("Nothing else today.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(items), id: \.uid) { item in
                    HStack(spacing: Spacing.xs) {
                        RoundedRectangle(cornerRadius: 1.5).fill(item.tint).frame(width: 3, height: Spacing.xl)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                            Text(item.start <= context.date ? String(localized: "Now · until \(AgendaText.time(item.end))") : AgendaText.range(item))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(item.start <= context.date ? Color.accent : Color.secondary)
                        }
                        Spacer(minLength: 0)
                        if let conference = item.conference {
                            JoinButton(url: conference, prominent: item.start.timeIntervalSince(context.date) < 15 * 60)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        WorkspaceRouter.shared.tab = .calendar
                        WorkspaceRouter.shared.focusedAgendaItem = item.id
                        openMain()
                    }
                }
                TextField("New event… (in French) “Point lundi 9h /pro”", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .disabled(sending)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.xs + 2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.xs + 2, style: .continuous).strokeBorder(Color.line))
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let parsed = self.parsed
                    ParsedEventPreview(parsed: parsed, calendar: parsed.needsGoogle ? nil : store.calendar(id: parsed.calendarId ?? CalendarBridge.shared.defaultCalendarId))
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(Color.bad) }
            }
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !sending else { return }
        let result = parsed
        sending = true
        failure = nil
        Task {
            do {
                try await CalendarBridge.shared.create(EventDraft(result, calendarId: CalendarBridge.shared.defaultCalendarId))
                text = ""
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
