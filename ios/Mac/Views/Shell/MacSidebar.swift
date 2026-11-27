import SwiftUI

struct MacSidebar: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @State private var reminders = RemindersStore.shared
    @State private var home = FilesHomeStore.shared
    @State private var agenda = CalendarStore.shared
    @State private var booking = BookingStore.shared
    @State private var confirmDelete: Bot?
    @State private var deleteFailure: String?
    @State private var deleteProject: ReminderProject?
    @State private var deleteArea: ReminderArea?

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.sidebar) {
            Section {
                ForEach(bots.pinnedFirst) { bot in
                    BotSidebarRow(bot: bot, running: session.turns.isRunning(bot))
                        .tag(SidebarItem.bot(bot.id))
                        .contextMenu {
                            Button(bots.isPinned(bot) ? String(localized: "Unpin") : String(localized: "Pin")) { bots.setPinned(bot, !bots.isPinned(bot)) }
                            Button("New Conversation") { navigator.newConversation(botId: bot.id) }
                            Button("Edit Bot…") { navigator.editor = EditorTarget(botId: bot.id) }
                            Button("Memory") {
                                navigator.sidebar = .memory
                                navigator.memoryBot = bot.id
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { confirmDelete = bot }
                        }
                }
                if bots.bots.isEmpty && bots.isLoading {
                    ProgressView().controlSize(.small)
                } else if let error = bots.loadError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bots.bots.isEmpty ? String(localized: "Couldn't load the bots.") : String(localized: "The bot list is out of date."))
                            .font(.caption.weight(.semibold))
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Button("Try again") { Task { await bots.load() } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Bots")
                    Spacer()
                    Button { navigator.showsNewBot = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("New bot (⇧⌘N)")
                        .accessibilityLabel("New bot")
                }
            }

            Section("Calendar") {
                Label("Agenda", systemImage: "calendar")
                    .badge(todayCount)
                    .tag(SidebarItem.calendar)
                Label("Bookings", systemImage: "calendar.badge.clock")
                    .badge(booking.bookings.count)
                    .tag(SidebarItem.booking)
            }

            Section("Meetings") {
                MeetingSidebarRow()
                    .tag(SidebarItem.meetings)
            }

            Section("Files") {
                Label("Dashboards", systemImage: "chart.bar.xaxis")
                    .badge(home.dashboards.count)
                    .tag(SidebarItem.dashboards)
                Label("Collections", systemImage: "tablecells")
                    .badge(home.collections.count)
                    .tag(SidebarItem.collections)
                Label("Docs", systemImage: "doc.text")
                    .tag(SidebarItem.docs)
            }

            Section("Reminders") {
                ForEach(ReminderSmartList.smartLists, id: \.self) { list in
                    SmartListRow(list: list)
                        .tag(SidebarItem.reminders(list))
                }
            }

            Section {
                ForEach(reminders.sortedAreas) { area in
                    AreaSidebarRow(area: area)
                        .tag(SidebarItem.reminders(.area(area.id)))
                        .contextMenu { areaMenu(area) }
                    ForEach(reminders.openProjects(in: area.id)) { project in
                        projectRow(project)
                    }
                }
                ForEach(reminders.openProjects(in: nil)) { project in
                    projectRow(project)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Menu {
                        Button("New Project") { navigator.newProject() }
                        Button("New Area") { navigator.newArea() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("New project (⌥⌘N) or area (⇧⌥⌘N)")
                    .accessibilityLabel("New project or area")
                }
            }

            Section("Automation") {
                Label("Scheduled Tasks", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.schedules)
                Label("Alerts", systemImage: "bell")
                    .badge(AlertsStore.shared.unreadCount)
                    .tag(SidebarItem.alerts)
                Label("Memory", systemImage: "brain")
                    .tag(SidebarItem.memory)
                Button {
                    openWindow(id: MacWindow.browser)
                } label: {
                    Label("Browser", systemImage: "safari")
                }
                .buttonStyle(.plain)
                .help("The gateway's browser, where you sign in to the sites your agents use")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { connectionFooter }
        .onChange(of: navigator.sidebar) { _, item in
            // A bot that is answering opens on that conversation rather than on a new one.
            guard case let .bot(id)? = item, navigator.chat?.conversationId == nil,
                  let bot = bots.bot(id: id), let running = session.turns.runningConversation(for: bot) else { return }
            navigator.chat = ChatSelection(botId: id, conversationId: running)
        }
        .confirmationDialog("Delete “\(confirmDelete?.config?.name ?? "")”?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete bot", role: .destructive) {
                guard let bot = confirmDelete else { return }
                Task {
                    do {
                        try await bots.delete(bot)
                        if navigator.currentBotId == bot.id { navigator.sidebar = .reminders(.today) }
                    } catch {
                        deleteFailure = String(localized: "“\(bot.config?.name ?? String(localized: "Bot"))” wasn't deleted: \(error.localizedDescription)")
                    }
                }
            }
        } message: {
            Text("Its conversations and versions are deleted from the gateway.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteFailure ?? "")
        }
        .confirmationDialog("Delete “\(deleteProject?.title ?? "")”?",
                            isPresented: Binding(get: { deleteProject != nil }, set: { if !$0 { deleteProject = nil } }), titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                guard let project = deleteProject else { return }
                if navigator.sidebar == .reminders(.project(project.id)) { navigator.sidebar = .reminders(.anytime) }
                Task { await reminders.deleteProject(project.id) }
            }
        } message: {
            Text("Its sections and reminders are deleted with it.")
        }
        .confirmationDialog("Delete “\(deleteArea?.title ?? "")”?",
                            isPresented: Binding(get: { deleteArea != nil }, set: { if !$0 { deleteArea = nil } }), titleVisibility: .visible) {
            Button("Delete area", role: .destructive) {
                guard let area = deleteArea else { return }
                if navigator.sidebar == .reminders(.area(area.id)) { navigator.sidebar = .reminders(.anytime) }
                Task { await reminders.deleteArea(area.id) }
            }
        } message: {
            Text("Its projects and reminders are kept, with no area.")
        }
    }

    private func projectRow(_ project: ReminderProject) -> some View {
        ProjectSidebarRow(project: project)
            .tag(SidebarItem.reminders(.project(project.id)))
            .contextMenu { projectMenu(project) }
    }

    @ViewBuilder
    private func areaMenu(_ area: ReminderArea) -> some View {
        Button("New Project in This Area") { navigator.newProject(areaId: area.id) }
        Divider()
        Button("Rename…") { navigator.namePrompt = NamePrompt(kind: .renameArea(area.id), text: area.title) }
        Button("Emoji…") { navigator.namePrompt = NamePrompt(kind: .areaEmoji(area.id), text: area.emoji ?? "") }
        Divider()
        Button("Delete…", role: .destructive) { deleteArea = area }
    }

    @ViewBuilder
    private func projectMenu(_ project: ReminderProject) -> some View {
        Button("Rename…") { navigator.namePrompt = NamePrompt(kind: .renameProject(project.id), text: project.title) }
        Button("Emoji…") { navigator.namePrompt = NamePrompt(kind: .projectEmoji(project.id), text: project.emoji ?? "") }
        Menu("Move to Area") { ProjectAreaMenu(project: project) }
        Button(project.someday ? String(localized: "Take Out of “Someday”") : String(localized: "Put in “Someday”")) {
            Task { await reminders.updateProject(project.id, patch: ["someday": .bool(!project.someday)]) }
        }
        Divider()
        // The sidebar has no room for the « keep the open reminders? » question: the project screen asks it.
        let open = reminders.openReminders(inProject: project.id).count
        Button("Finish Project") {
            if open > 0 { navigator.sidebar = .reminders(.project(project.id)) } else { Task { await reminders.finishProject(project.id) } }
        }
        Button("Cancel Project") {
            if open > 0 { navigator.sidebar = .reminders(.project(project.id)) } else { Task { await reminders.finishProject(project.id, cancel: true) } }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleteProject = project }
    }

    /// Timed events still to come today.
    private var todayCount: Int {
        let now = Date()
        return agenda.items(on: now).filter { $0.kind == .event && !$0.allDay && $0.end > now }.count
    }

    private var connectionFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(connectionLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var connectionColor: Color {
        if session.isDemo { return Color.accent }
        switch session.connectionState {
        case .connected: return Color.good
        case .connecting: return Color(hex: 0xF59E0B)
        default: return Color.bad
        }
    }

    private var connectionLabel: String {
        if session.isDemo { return String(localized: "Demo mode") }
        switch session.connectionState {
        case .connected: return session.gatewayDisplay
        case .connecting: return String(localized: "Connecting…")
        default: return String(localized: "Offline")
        }
    }
}

private struct BotSidebarRow: View {
    let bot: Bot
    let running: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(bot.config?.name ?? String(localized: "Bot")).lineLimit(1)
                    if running {
                        Spacer(minLength: 0)
                        RunningBadge()
                    }
                }
                if let preview = bot.lastMessagePreview, !preview.isEmpty {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            Text(bot.config?.emoji ?? "✨")
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .background(Color(hexString: bot.config?.color ?? "") ?? Color.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// Inbox and Today show their counts, Today with the overdue ones in red first (Things' badge).
private struct SmartListRow: View {
    let list: ReminderSmartList
    @State private var store = RemindersStore.shared

    var body: some View {
        Label { Text(list.title) } icon: { Image(systemName: list.symbol).foregroundStyle(list.tint) }
            .badge(badge)
            .reminderDropTarget { ids in
                switch list {
                case .inbox: store.macMove(ids, to: .inbox)
                case .someday: for reminder in ids.compactMap(store.reminder(id:)) where !reminder.isSomeday { Task { await store.setSomeday(reminder, true) } }
                default: return false
                }
                return true
            }
    }

    private var badge: Text? {
        switch list {
        case .inbox:
            let count = store.count(in: .inbox)
            return count > 0 ? Text("\(count)") : nil
        case .today:
            let count = store.count(in: .today)
            let overdue = store.count(.overdue)
            guard count > 0 else { return nil }
            guard overdue > 0 else { return Text("\(count)") }
            let late = Text("\(overdue)").foregroundStyle(Color.bad).fontWeight(.semibold)
            return overdue == count ? late : Text("\(late)  \(count - overdue)")
        default:
            return nil
        }
    }
}

private struct AreaSidebarRow: View {
    let area: ReminderArea
    @State private var store = RemindersStore.shared

    var body: some View {
        Label {
            Text(area.title).fontWeight(.semibold)
        } icon: {
            if let emoji = area.emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 13))
            } else {
                Image(systemName: "square.stack.3d.up")
            }
        }
        .reminderDropTarget { ids in
            store.macMove(ids, to: .area(area.id))
            return true
        }
    }
}

private struct ProjectSidebarRow: View {
    let project: ReminderProject
    @State private var store = RemindersStore.shared

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(RemindersStore.macLabel(project.title, emoji: project.emoji)).lineLimit(1)
                if let date = project.deadlineDate {
                    Spacer(minLength: 4)
                    let days = store.macDaysLeft(project)
                    Text(ProjectDeadlineText.short(date, daysLeft: days))
                        .font(.caption)
                        .foregroundStyle((days ?? 1) <= 0 ? Color.bad : Color.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            ProjectPie(progress: store.macProgress(project), tint: project.someday ? Color.text3 : Color.accent)
        }
        .reminderDropTarget { ids in
            store.macMove(ids, to: .project(project.id, heading: nil))
            return true
        }
    }
}

private extension View {
    /// Reminders dragged from a list onto a sidebar row are filed there.
    func reminderDropTarget(_ action: @escaping ([String]) -> Bool) -> some View {
        dropDestination(for: String.self) { ids, _ in
            let known = ids.filter { RemindersStore.shared.reminder(id: $0) != nil }
            return known.isEmpty ? false : action(known)
        }
    }
}

private struct MeetingSidebarRow: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text("Meetings")
                if recorder.isRecording {
                    Spacer(minLength: 0)
                    MeetingRecordingBadge()
                }
            }
        } icon: {
            Image(systemName: "waveform")
        }
    }
}
