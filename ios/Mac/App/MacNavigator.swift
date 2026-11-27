import Foundation
import Observation
import SwiftUI

/// Things-like reminder routes: the smart lists, then an area or a project of the sidebar.
enum ReminderSmartList: Hashable {
    case inbox, today, upcoming, anytime, someday, logbook
    case area(String)
    case project(String)

    static let smartLists: [ReminderSmartList] = [.inbox, .today, .upcoming, .anytime, .someday, .logbook]

    var bucket: ReminderBucket? {
        switch self {
        case .inbox: .inbox
        case .today: .today
        case .upcoming: .upcoming
        case .anytime: .anytime
        case .someday: .someday
        case .logbook: .logbook
        case .area, .project: nil
        }
    }

    @MainActor var title: String {
        switch self {
        case let .area(id): RemindersStore.shared.area(id: id)?.title ?? String(localized: "Area")
        case let .project(id): RemindersStore.shared.project(id: id)?.title ?? String(localized: "Project")
        default: bucket?.label ?? ""
        }
    }

    var symbol: String {
        switch self {
        case .area: "square.stack.3d.up"
        case .project: "circle.circle"
        default: bucket?.symbol ?? "tray"
        }
    }

    var tint: Color {
        switch self {
        case .inbox: Color(hex: 0x3B82F6)
        case .today: Color(hex: 0xF5B400)
        case .upcoming: Color(hex: 0xE5484D)
        case .anytime: Color(hex: 0x14B8A6)
        case .someday: Color(hex: 0xC2A26B)
        case .logbook: Color.good
        case .area, .project: Color.text2
        }
    }

    /// Lists sorted by `position`, where a drag reorders the rows.
    var isReorderable: Bool {
        switch self {
        case .inbox, .someday, .area, .project: true
        default: false
        }
    }

    /// Where ⌘N and the inline entry file a new reminder.
    var destination: ReminderDestination? {
        switch self {
        case let .area(id): .area(id)
        case let .project(id): .project(id, heading: nil)
        default: nil
        }
    }
}

enum SidebarItem: Hashable {
    case bot(String)
    case calendar, booking
    case dashboards, collections, docs
    case reminders(ReminderSmartList)
    case schedules
    case alerts
    case memory
    case meetings

    var section: MacSection {
        switch self {
        case .bot: .bots
        case .calendar, .booking: .calendar
        case .dashboards, .collections, .docs: .files
        case .reminders: .reminders
        case .schedules, .alerts: .schedules
        case .memory: .memory
        case .meetings: .meetings
        }
    }
}

enum MacSection: Int, CaseIterable, Identifiable {
    case bots, calendar, files, reminders, schedules, memory, meetings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .bots: "Bots"
        case .calendar: String(localized: "Calendar")
        case .files: String(localized: "Files")
        case .reminders: String(localized: "Reminders")
        case .schedules: String(localized: "Tasks")
        case .memory: String(localized: "Memory")
        case .meetings: String(localized: "Meetings")
        }
    }
}

/// A chat shown in the detail column or in its own window.
struct ChatSelection: Hashable, Codable {
    var botId: String
    var conversationId: String?
    var useDraft = false
    /// Distinguishes two "new conversation" selections of the same bot.
    var token = UUID()
}

/// Selection of the main window: sidebar item, item of the content column and the sheets it opens.
/// Translates the shared `AppRouter` / `WorkspaceRouter` intents (notifications, `nuo://` links) into it.
@MainActor
@Observable
final class MacNavigator {
    var sidebar: SidebarItem? = .reminders(.today) {
        didSet {
            guard oldValue != sidebar else { return }
            workspace.filesPath = []
            if case let .bot(id)? = sidebar, chat?.botId != id { chat = ChatSelection(botId: id) }
        }
    }
    var chat: ChatSelection?
    var dashboard: String?
    var collection: String?
    var doc: String?
    var reminderSelection: Set<String> = []
    var schedule: String?
    var alert: String?
    var memoryBot: String?

    var calendarMode: MacCalendarMode = MacCalendarMode(rawValue: UserDefaults.standard.string(forKey: "nuo.mac.calendar.mode") ?? "") ?? .week {
        didSet { UserDefaults.standard.set(calendarMode.rawValue, forKey: "nuo.mac.calendar.mode") }
    }
    var calendarDate = AgendaCalendar.current.startOfDay(for: Date())
    /// Agenda item shown in the inspector.
    var calendarSelection: String?
    /// Bumped by ⌘N in the calendar: focuses the quick entry field.
    var calendarEntryFocus = 0
    /// Bumped when a day is picked: the list view scrolls to it.
    var calendarJump = 0

    var showsPalette = false
    var showsQuickEntry = false
    var showsNewBot = false
    /// Rename, emoji or new area prompt of the reminders sidebar and menus.
    var namePrompt: NamePrompt?
    /// A project just created: its screen focuses the title field once.
    var focusProjectTitle: String?
    var newSchedule = false
    var editor: EditorTarget?
    /// Bumped by ⌘F: the screen on display focuses its search field.
    var searchFocus = 0
    /// Folder of the Docs tree to expand and select (`nuo://docs/<folder>`), cleared by the tree once shown.
    var revealFolder: String?
    /// Bumped by ⌘R; screens reload when it changes.
    var refreshTick = 0
    /// Palette action run once its sheet is gone: a sheet presented while another one closes is dropped.
    @ObservationIgnored var pendingPaletteAction: (@MainActor () -> Void)?

    @ObservationIgnored let workspace = WorkspaceRouter.shared
    @ObservationIgnored let router = AppRouter.shared

    var section: MacSection { sidebar?.section ?? .bots }

    func show(_ section: MacSection, bots: [Bot]) {
        switch section {
        case .bots: sidebar = bots.first.map { .bot($0.id) }
        case .calendar: sidebar = .calendar
        case .files: sidebar = .dashboards
        case .reminders: sidebar = .reminders(.today)
        case .schedules: sidebar = .schedules
        case .memory: sidebar = .memory
        case .meetings: sidebar = .meetings
        }
    }

    func openChat(_ selection: ChatSelection) {
        sidebar = .bot(selection.botId)
        chat = selection
    }

    func newConversation(botId: String?) {
        guard let botId = botId ?? currentBotId else { return }
        openChat(ChatSelection(botId: botId))
    }

    var currentBotId: String? {
        if case let .bot(id) = sidebar { return id }
        return chat?.botId
    }

    func refresh() { refreshTick += 1 }

    func focusSearch() {
        searchFocus += 1
    }

    func runPendingPaletteAction() {
        let action = pendingPaletteAction
        pendingPaletteAction = nil
        action?()
    }

    /// ⌘N: a conversation with the bot on screen, an event in the calendar, a reminder elsewhere.
    func newItem(bots: [Bot]) {
        switch section {
        case .bots: newConversation(botId: currentBotId ?? bots.first?.id)
        case .calendar:
            if sidebar != .calendar { sidebar = .calendar }
            calendarEntryFocus += 1
        case .schedules: newSchedule = true
        default: showsQuickEntry = true
        }
    }

    // MARK: Projects

    /// ⌥⌘N: an empty project in the area on screen, opened with its title ready to type.
    func newProject(areaId: String? = nil) {
        let area = areaId ?? currentReminderArea
        Task {
            guard let project = await RemindersStore.shared.createProject(ProjectDraft(title: String(localized: "New Project"), areaId: area)) else { return }
            focusProjectTitle = project.id
            reminderSelection = []
            sidebar = .reminders(.project(project.id))
        }
    }

    func newArea() {
        namePrompt = NamePrompt(kind: .newArea, text: "")
    }

    var currentReminderArea: String? {
        switch sidebar {
        case let .reminders(.area(id))?: id
        case let .reminders(.project(id))?: RemindersStore.shared.project(id: id)?.areaId
        default: nil
        }
    }

    var currentReminderDestination: ReminderDestination? {
        if case let .reminders(list)? = sidebar { return list.destination }
        return nil
    }

    // MARK: Shared routers

    /// Notification taps and `nuo://` links end up in the shared routers; mirror them here.
    func consumeRouters(bots: [Bot]) {
        if let route = router.path.last {
            router.path = []
            switch route {
            case let .chat(target):
                openChat(ChatSelection(botId: target.botId, conversationId: target.conversationId, useDraft: target.useDraft))
            case let .conversations(botId):
                sidebar = .bot(botId)
            case let .schedule(taskId):
                sidebar = .schedules
                schedule = taskId
            case .settings:
                MacWindowRequests.shared.showSettings()
            }
        }
        if let target = router.editor {
            router.editor = nil
            editor = target
        }
    }

    func consumeWorkspace() {
        if workspace.showsMeetings {
            workspace.showsMeetings = false
            sidebar = .meetings
        }
        switch workspace.tab {
        case .files:
            workspace.tab = .bots
            let path = workspace.filesPath
            guard let first = path.first else { sidebar = .dashboards; return }
            switch first {
            case let .collection(id):
                sidebar = .collections
                collection = id
            case let .row(collection: id, _):
                sidebar = .collections
                collection = id
            case .dashboards:
                sidebar = .dashboards
            case let .dashboard(slug):
                sidebar = .dashboards
                dashboard = slug
            case let .folder(folder):
                sidebar = .docs
                revealFolder = folder
            case let .doc(path):
                sidebar = .docs
                doc = path
            }
            // The table selects the row itself; only rows reached from a dashboard are pushed.
            workspace.filesPath = Array(path.dropFirst()).filter { if case .row = $0 { return false }; return true }
            if case let .row(_, rowId)? = path.last { pendingRow = rowId }
        case .reminders:
            workspace.tab = .bots
            if case .reminders? = sidebar {} else { sidebar = .reminders(.today) }
            if let id = workspace.focusedReminder {
                workspace.focusedReminder = nil
                focusReminder(id)
            }
        case .calendar:
            workspace.tab = .bots
            if workspace.showsBookings {
                workspace.showsBookings = false
                sidebar = .booking
            } else {
                sidebar = .calendar
            }
            if let id = workspace.focusedAgendaItem {
                workspace.focusedAgendaItem = nil
                Task { await focusAgendaItem(id) }
            }
        case .bots:
            break
        }
    }

    /// The agenda may still be loading when a notification is tapped at launch.
    func focusAgendaItem(_ id: String) async {
        let store = CalendarStore.shared
        if store.item(id: id) == nil { await store.load() }
        guard let item = store.item(id: id) else { return }
        calendarDate = AgendaCalendar.current.startOfDay(for: item.start)
        calendarSelection = item.uid
    }

    /// Row to select once the collection table has loaded (link to `nuo://data/<collection>/<row>`).
    var pendingRow: String?

    func focusReminder(_ id: String) {
        // WorkspaceRouter carries `nuo://reminders/project/<id>` and `/area/<id>` in the same field.
        if id.hasPrefix("project/") {
            sidebar = .reminders(.project(String(id.dropFirst("project/".count))))
            return
        }
        if id.hasPrefix("area/") {
            sidebar = .reminders(.area(String(id.dropFirst("area/".count))))
            return
        }
        let store = RemindersStore.shared
        if let reminder = store.reminder(id: id) {
            sidebar = .reminders(Self.smartList(for: reminder, store: store))
            reminderSelection = [id]
            return
        }
        // Tapped at launch, before the reminders are loaded.
        reminderSelection = [id]
        Task {
            await store.load()
            guard reminderSelection == [id], let reminder = store.reminder(id: id) else { return }
            sidebar = .reminders(Self.smartList(for: reminder, store: store))
            reminderSelection = [id]
        }
    }

    static func smartList(for reminder: Reminder, store: RemindersStore) -> ReminderSmartList {
        if reminder.isDone { return reminder.projectId.map(ReminderSmartList.project) ?? .logbook }
        if let projectId = reminder.projectId { return .project(projectId) }
        for list in [ReminderSmartList.today, .upcoming, .inbox] where store.items(in: list.bucket!).contains(where: { $0.id == reminder.id }) {
            return list
        }
        if let areaId = reminder.areaId { return .area(areaId) }
        return reminder.isSomeday ? .someday : .anytime
    }

    // MARK: Demo

    /// `-demoScreen bots|calendar|calendarquick|calendarmonth|calendarday|calendarevent|booking|dashboard|collection|reminders|docs|schedules|memory`
    /// (`inbox|anytime|someday|logbook`, `project -demoItem prj-japon`, `area -demoItem area-maison`) for scripted screenshots.
    func applyDemo(bots: [Bot]) {
        guard let screen = DemoDirector.screen else { return }
        switch screen {
        case "bots", "chat":
            openChat(ChatSelection(botId: "voyages", conversationId: "c-voyages-1"))
        case "coach":
            openChat(ChatSelection(botId: "coach", conversationId: "c-coach-1"))
        case "cobot":
            openChat(ChatSelection(botId: "cobot", conversationId: "c-cobot-1"))
        case "dashboard":
            sidebar = .dashboards
            dashboard = DemoDirector.argument("-demoItem") ?? FilesHomeStore.shared.dashboards.first?.slug
        case "collection":
            sidebar = .collections
            collection = DemoDirector.argument("-demoItem") ?? FilesHomeStore.shared.collections.first?.id
        case "reminders":
            sidebar = .reminders(.today)
            if DemoDirector.argument("-demoItem") == "first", let first = RemindersStore.shared.items(in: .today).first {
                reminderSelection = [first.id]
            }
        case "quickentry":
            sidebar = .reminders(.today)
            showsQuickEntry = true
        case "upcoming":
            sidebar = .reminders(.upcoming)
        case "inbox", "anytime", "someday", "logbook":
            sidebar = .reminders(ReminderSmartList.smartLists.first { $0.bucket?.rawValue == screen } ?? .today)
        case "project":
            let id = DemoDirector.argument("-demoItem") ?? "prj-japon"
            sidebar = .reminders(.project(id))
            if let reminder = DemoDirector.argument("-demoReminder") { reminderSelection = [reminder] }
        case "area":
            sidebar = .reminders(.area(DemoDirector.argument("-demoItem") ?? "area-maison"))
        case "docs":
            sidebar = .docs
            doc = DemoDirector.argument("-demoItem") ?? FilesHomeStore.shared.recentDocs.first?.path
        case "schedules":
            sidebar = .schedules
            schedule = DemoDirector.argument("-demoItem")
        case "memory":
            sidebar = .memory
            memoryBot = DemoDirector.argument("-demoItem") ?? bots.first?.id
        case "calendar", "calendarquick", "calendarmonth", "calendarday", "calendarevent":
            sidebar = .calendar
            calendarMode = screen == "calendarmonth" ? .month : screen == "calendarday" ? .day : .week
            if screen == "calendarquick" { calendarEntryFocus += 1 }
            if screen == "calendarevent", let title = DemoDirector.argument("-demoItem") ?? Optional(String(localized: "Team lunch")),
               let item = CalendarStore.shared.items.first(where: { $0.title == title }) {
                calendarDate = AgendaCalendar.current.startOfDay(for: item.start)
                calendarSelection = item.uid
            }
        case "booking":
            sidebar = .booking
        case "meetings", "meeting", "meetingnote":
            sidebar = .meetings
        case "palette":
            openChat(ChatSelection(botId: "voyages", conversationId: "c-voyages-1"))
            showsPalette = true
        default:
            break
        }
    }
}

extension FocusedValues {
    @Entry var navigator: MacNavigator?
}
