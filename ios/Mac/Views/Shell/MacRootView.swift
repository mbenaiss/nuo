import AppKit
import SwiftUI

/// Frames the pairing flow or the main split. Startup and routing run app-wide in `MacAppController`, which owns
/// the navigator: they keep working with this window closed.
struct MacRootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var lock = AppLock.shared

    var body: some View {
        Group {
            switch session.phase {
            case .locked:
                LockedSessionView()
            case .pairing:
                // The pairing flow (code + second factor) belongs to the shared auth work; the Mac only frames it.
                PairingView()
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.canvas)
            case .ready:
                MainSplitView()
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .appLock()
        // Menus act on the navigator: none while pairing or locked.
        .focusedSceneValue(\.navigator, session.phase == .ready && !lock.isLocked ? navigator : nil)
        .onOpenURL { url in MacAppController.current?.open(url: url) }
    }
}

struct MainSplitView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator
    @State private var columns: NavigationSplitViewVisibility = Self.initialColumns

    private static var initialColumns: NavigationSplitViewVisibility {
        guard DemoDirector.argument("-demoSidebar") == "hidden" else { return .all }
        if DemoDirector.screen?.hasPrefix("calendar") == true || DemoDirector.screen == "booking" { return .detailOnly }
        return ["reminders", "upcoming", "quickentry", "inbox", "anytime", "someday", "logbook", "project", "area"].contains(DemoDirector.screen)
            ? .detailOnly : .doubleColumn
    }
    @State private var schedules = SchedulesStore()

    var body: some View {
        @Bindable var navigator = navigator
        splitView
        .overlay(alignment: .top) {
            AnswerBannerHost().frame(maxWidth: 460).padding(.top, 6)
        }
        .sheet(isPresented: $navigator.showsPalette, onDismiss: { navigator.runPendingPaletteAction() }) {
            CommandPaletteView()
        }
        .sheet(isPresented: $navigator.showsQuickEntry) {
            QuickEntryPanel(destination: navigator.currentReminderDestination)
        }
        .namePrompt($navigator.namePrompt)
        .sheet(isPresented: $navigator.showsNewBot) {
            NewBotSheet().frame(minWidth: 460, minHeight: 420)
        }
        .sheet(item: $navigator.editor) { target in
            BotEditorView(botId: target.botId).frame(minWidth: 620, idealWidth: 680, minHeight: 640, idealHeight: 760)
        }
        .sheet(isPresented: $navigator.newSchedule) {
            ScheduleEditorView(store: schedules, original: nil, defaultBotId: navigator.currentBotId)
                .frame(minWidth: 560, minHeight: 620)
        }
        .task {
            schedules.attach(session.api)
        }
    }

    /// Reminders take the whole width (Things style, editor in the inspector); every other section is a native
    /// three-column split, which clamps the list and detail to the window and gives each column its own toolbar.
    @ViewBuilder
    private var splitView: some View {
        if navigator.sidebar == .calendar || navigator.sidebar == .booking {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                if navigator.sidebar == .booking {
                    NavigationStack { BookingHomeView().readableColumn() }
                } else {
                    MacCalendarView()
                }
            }
        } else if case .reminders? = navigator.sidebar {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                reminders
            }
        } else {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } content: {
                contentColumn
                    .navigationTitle(contentTitle)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
            } detail: {
                detailColumn
                    .navigationSplitViewColumnWidth(min: 420, ideal: 760)
            }
        }
    }

    private var contentTitle: String {
        switch navigator.sidebar {
        case let .bot(id)?: bots.bot(id: id)?.config?.name ?? String(localized: "Bot")
        case .calendar?: String(localized: "Calendar")
        case .booking?: String(localized: "Bookings")
        case .dashboards?: String(localized: "Dashboards")
        case .collections?: String(localized: "Collections")
        case .docs?: String(localized: "Docs")
        case .schedules?: String(localized: "Scheduled Tasks")
        case .alerts?: String(localized: "Alerts")
        case .memory?: String(localized: "Memory")
        case .meetings?: String(localized: "Meetings")
        case .reminders?, nil: "Nuo"
        }
    }

    private var sidebar: some View {
        MacSidebar()
            .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
    }

    @ViewBuilder
    private var reminders: some View {
        @Bindable var navigator = navigator
        if case let .reminders(list)? = navigator.sidebar {
            ReminderListView(list: list)
                .id(list)
                .inspector(isPresented: Binding(get: { !navigator.reminderSelection.isEmpty }, set: { if !$0 { navigator.reminderSelection = [] } })) {
                    ReminderInspector().inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch navigator.sidebar {
        case let .bot(id)?:
            ConversationList(botId: id)
        case .calendar?, .booking?:
            EmptyView()
        case .dashboards?:
            DashboardList()
        case .collections?:
            CollectionList()
        case .docs?:
            DocsTree()
        case .reminders?:
            EmptyView()
        case .schedules?:
            ScheduleList(store: schedules)
        case .alerts?:
            MacAlertsList()
        case .memory?:
            MemoryBotList()
        case .meetings?:
            MeetingsList()
        case nil:
            ContentUnavailableView("Nuo", systemImage: "sidebar.left", description: Text("Choose a section in the sidebar."))
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch navigator.sidebar {
        case .bot?:
            ChatDetail()
        case .calendar?, .booking?:
            EmptyView()
        case .dashboards?:
            FilesStack {
                if let slug = navigator.dashboard {
                    MacDashboardView(slug: slug).id(slug)
                } else {
                    ContentUnavailableView("No dashboard", systemImage: "chart.bar.xaxis", description: Text("Choose a dashboard."))
                }
            }
        case .collections?:
            FilesStack {
                if let id = navigator.collection {
                    CollectionTableView(collectionId: id).id(id)
                } else {
                    ContentUnavailableView("No collection", systemImage: "tablecells", description: Text("Choose a collection."))
                }
            }
        case .docs?:
            FilesStack {
                if let path = navigator.doc {
                    DocPane(path: path).id(path)
                } else {
                    ContentUnavailableView("No document", systemImage: "doc.text", description: Text("Choose a document or create one."))
                }
            }
        case .reminders?:
            ReminderInspector()
        case .alerts?:
            if let id = navigator.alert, let alert = AlertsStore.shared.items.first(where: { $0.id == id }) {
                AlertDetailView(alert: alert) { NotificationRouter.open(NotificationDestination(alert.destination)) }
                    .id(id)
            } else {
                ContentUnavailableView("No alert", systemImage: "bell", description: Text("Choose an alert."))
            }
        case .schedules?:
            NavigationStack {
                if let id = navigator.schedule {
                    ScheduleDetailView(store: schedules, taskId: id).id(id).readableColumn()
                } else {
                    ContentUnavailableView("No task", systemImage: "clock.arrow.circlepath", description: Text("Choose a scheduled task."))
                }
            }
        case .memory?:
            NavigationStack {
                if let id = navigator.memoryBot {
                    BotMemoryView(botId: id).id(id).readableColumn()
                } else {
                    ContentUnavailableView("Memory", systemImage: "brain", description: Text("Choose a bot."))
                }
            }
        case .meetings?:
            FilesStack {
                if let path = navigator.doc, path.hasPrefix("reunions/") {
                    DocPane(path: path).id(path)
                } else {
                    ContentUnavailableView("Meetings", systemImage: "waveform",
                                           description: Text("Transcribe a meeting (⇧⌘R): the microphone and the Mac's sound are transcribed on this Mac, then a bot writes the note."))
                }
            }
        case nil:
            Color.canvas
        }
    }
}

/// Detail of the Fichiers items: dashboard rows and links inside docs push onto the shared files path.
struct FilesStack<Root: View>: View {
    @Environment(WorkspaceRouter.self) private var workspace
    @ViewBuilder let root: () -> Root

    var body: some View {
        @Bindable var workspace = workspace
        NavigationStack(path: $workspace.filesPath) {
            root()
                .navigationDestination(for: FilesRoute.self) { route in
                    switch route {
                    case let .collection(id): CollectionTableView(collectionId: id)
                    case let .row(collection, id): RowDetailView(collectionId: collection, rowId: id, seed: nil)
                    case .dashboards: DashboardsListView()
                    case let .dashboard(slug): MacDashboardView(slug: slug)
                    case let .folder(path): DocsFolderView(path: path)
                    case let .doc(path): DocPane(path: path)
                    }
                }
        }
    }
}

private struct ChatDetail: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator

    var body: some View {
        if let selection = navigator.chat, let bot = bots.bot(id: selection.botId), navigator.currentBotId == selection.botId {
            ChatPane(selection: selection, bot: bot, session: session, bots: bots) {
                navigator.newConversation(botId: selection.botId)
            }
            .onConversationCreated { id in navigator.chat?.conversationId = id }
            .id(selection.token)
        } else {
            WorkspaceEmptyState(symbol: "bubble.left.and.text.bubble.right", title: String(localized: "No bot"), message: String(localized: "Create a bot to get started."), mascot: .idle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension View {
    /// Shared detail screens are laid out for a phone: on a wide window they read as a centered column instead of
    /// stretching their buttons and rows edge to edge.
    func readableColumn(_ width: CGFloat = 760) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .background(Color.canvas)
    }
}
