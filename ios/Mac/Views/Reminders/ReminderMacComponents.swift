import SwiftUI

enum ReminderMacMetrics {
    /// Horizontal inset of headers and entries above a list; rows of the inset list line up on it.
    static let gutter = Spacing.md
    static let headerTop: CGFloat = 18
    static let rowVertical: CGFloat = 4
    static let checkbox: CGFloat = 22
    static let sidebarPie: CGFloat = 14
    static let headerPie: CGFloat = 24
    static let groupGap: CGFloat = 18
}

/// Things' project pie: a ring with the done share filled as a wedge.
struct ProjectPie: View {
    let progress: Double
    var size: CGFloat = ReminderMacMetrics.sidebarPie
    var tint: Color = Color.accent

    var body: some View {
        let line = max(1.2, size / 11)
        ZStack {
            Circle().strokeBorder(tint, lineWidth: line)
            PieWedge(fraction: progress)
                .fill(tint)
                .padding(line * 2)
        }
        .frame(width: size, height: size)
        .animation(.snappy, value: progress)
        .accessibilityLabel(String(localized: "\(progress.formatted(.percent.precision(.fractionLength(0)))) done"))
    }
}

private struct PieWedge: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fraction > 0 else { return Path() }
        if fraction >= 1 { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A reminder row of the Mac lists: the shared look plus where it is filed, its checklist and « Un jour ».
struct MacReminderRow: View {
    let reminder: Reminder
    let list: ReminderSmartList
    let completing: Bool
    let onToggle: () -> Void
    @State private var store = RemindersStore.shared

    private var checked: Bool { reminder.isDone }

    private var segment: ReminderSegment {
        switch list {
        case .today: .today
        case .upcoming: .upcoming
        case .logbook: .done
        default: .overdue
        }
    }

    /// Inside its own project or area, or under its group title in À tout moment and Un jour, the caption would only repeat it.
    private var caption: String? {
        switch list {
        case .project: return nil
        case .anytime, .someday: return nil
        case let .area(id) where reminder.areaId == id && reminder.projectId == nil: return nil
        default: return store.macCaption(of: reminder)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MacReminderCheckbox(checked: checked, priority: reminder.priority, action: onToggle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if reminder.priority > 0, !checked {
                        Text(String(repeating: "!", count: reminder.priority))
                            .font(.body.weight(.heavy))
                            .foregroundStyle(ReminderStyle.priorityColor(reminder.priority))
                    }
                    Text(reminder.title)
                        .foregroundStyle(checked ? Color.text3 : Color.ink)
                        .strikethrough(checked && completing, color: Color.text3)
                        .lineLimit(2)
                }
                meta
            }
            Spacer(minLength: 0)
        }
        .opacity(completing ? 0.55 : 1)
        .animation(.easeOut(duration: 0.25), value: completing)
    }

    @ViewBuilder
    private var meta: some View {
        let date = reminder.effectiveDate
        let overdue = !checked && (date.map { $0 < Date() } ?? false)
        let snoozed = reminder.snoozedUntil != nil && reminder.snoozedUntil == date
        let checklist = reminder.checklist ?? []
        let showsSomeday = reminder.isSomeday && list != .someday
        if date != nil || reminder.repeat != nil || reminder.place != nil || caption != nil || !checklist.isEmpty || showsSomeday
            || reminder.notes?.isEmpty == false || (segment == .done && reminder.doneAt != nil) {
            HStack(spacing: 10) {
                if let date, segment != .done {
                    Label(ReminderStyle.dateLabel(date, segment: overdue ? .overdue : segment), systemImage: snoozed ? "moon.zzz.fill" : "clock")
                        .foregroundStyle(overdue ? Color.bad : Color.text2)
                }
                if segment == .done, let done = reminder.doneAt {
                    Label(ScheduleText.time(done), systemImage: "checkmark").foregroundStyle(Color.text3)
                }
                if let rule = reminder.repeat {
                    Label(RepeatText.short(rule), systemImage: "repeat").foregroundStyle(Color.text2).lineLimit(1)
                }
                if let place = reminder.place {
                    PlaceChip(name: place.name, trigger: reminder.placeTrigger)
                }
                if !checklist.isEmpty {
                    Label("\(checklist.filter(\.done).count)/\(checklist.count)", systemImage: "checklist")
                        .foregroundStyle(Color.text2)
                        .monospacedDigit()
                }
                if showsSomeday {
                    Label("Someday", systemImage: "archivebox").foregroundStyle(Color.text3)
                }
                if let caption {
                    Text(caption).foregroundStyle(Color.text3).lineLimit(1)
                }
                if reminder.notes?.isEmpty == false {
                    Image(systemName: "text.alignleft").foregroundStyle(Color.text3)
                }
            }
            .font(.caption)
            .labelStyle(TightLabelStyle())
        }
    }
}

struct MacReminderCheckbox: View {
    let checked: Bool
    var priority = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(checked ? Color.good : ReminderStyle.priorityColor(priority).opacity(priority > 0 ? 1 : 0.6), lineWidth: 1.6)
                Circle().fill(Color.good).scaleEffect(checked ? 1 : 0.2).opacity(checked ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(checked ? 1 : 0.4)
                    .opacity(checked ? 1 : 0)
            }
            .frame(width: ReminderMacMetrics.checkbox, height: ReminderMacMetrics.checkbox)
            .animation(.spring(response: 0.32, dampingFraction: 0.6), value: checked)
            .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checked ? String(localized: "Reopen") : String(localized: "Mark as done"))
    }
}

/// Title row of a group inside a list (day, heading, project): plain row rather than a section header, whose
/// floating style draws an edge-to-edge rule under the first group.
struct ReminderGroupTitle<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var tint: Color = Color.ink
    var first = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.bold()).foregroundStyle(tint)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                trailing
            }
            Divider()
        }
        .padding(.top, first ? 4 : ReminderMacMetrics.groupGap)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

extension ReminderGroupTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, tint: Color = Color.ink, first: Bool = false) {
        self.init(title: title, subtitle: subtitle, tint: tint, first: first) { EmptyView() }
    }
}

/// Inbox, then projects without area, then each area with its projects: shared by context menus and pickers.
struct ReminderDestinationMenu: View {
    let current: ReminderDestination?
    let action: (ReminderDestination) -> Void
    @State private var store = RemindersStore.shared

    var body: some View {
        button(String(localized: "Inbox"), systemImage: "tray", .inbox)
        Divider()
        ForEach(store.openProjects(in: nil)) { project in
            button(RemindersStore.macLabel(project.title, emoji: project.emoji), systemImage: nil, .project(project.id, heading: nil))
        }
        ForEach(store.sortedAreas) { area in
            Menu(RemindersStore.macLabel(area.title, emoji: area.emoji)) {
                button(String(localized: "Directly in “\(area.title)”"), systemImage: nil, .area(area.id))
                let projects = store.openProjects(in: area.id)
                if !projects.isEmpty { Divider() }
                ForEach(projects) { project in
                    button(RemindersStore.macLabel(project.title, emoji: project.emoji), systemImage: nil, .project(project.id, heading: nil))
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ title: String, systemImage: String?, _ destination: ReminderDestination) -> some View {
        let isCurrent = current == destination
        Button {
            action(destination)
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .disabled(isCurrent)
    }
}

/// Right click on a reminder; acts on the whole selection when the row is part of it.
struct ReminderContextMenu: View {
    let reminder: Reminder
    let targets: [Reminder]
    @State private var store = RemindersStore.shared

    var body: some View {
        Button(reminder.isDone ? String(localized: "Reopen") : String(localized: "Mark as done")) { targets.forEach { store.toggleDone($0) } }
        if !reminder.isDone {
            Menu("Snooze") {
                Button("In 1 hour") { targets.forEach { store.snooze($0, until: Date().addingTimeInterval(3600)) } }
                Button("Tonight 6 PM") { targets.forEach { store.snooze($0, until: Self.tonight) } }
                Button("Tomorrow 9 AM") { targets.forEach { store.snooze($0, until: ReminderNotifications.tomorrowMorning()) } }
                Button("Next Monday") { targets.forEach { store.snooze($0, until: Self.nextMonday) } }
            }
            Menu("Move To") {
                ReminderDestinationMenu(current: targets.count == 1 ? store.macDestination(of: reminder) : nil) { destination in
                    store.macMove(targets.map(\.id), to: destination)
                }
            }
            if let projectId = reminder.projectId, targets.allSatisfy({ $0.projectId == projectId }), !store.headings(ofProject: projectId).isEmpty {
                Menu("Move Under Section") {
                    Button("No section") { store.macMove(targets.map(\.id), to: .project(projectId, heading: nil)) }
                    Divider()
                    ForEach(store.headings(ofProject: projectId)) { heading in
                        Button(heading.title) { store.macMove(targets.map(\.id), to: .project(projectId, heading: heading.id)) }
                    }
                }
            }
            Button(reminder.isSomeday ? String(localized: "Remove from “Someday”") : String(localized: "File under “Someday”")) {
                let someday = !reminder.isSomeday
                for target in targets { Task { await store.setSomeday(target, someday) } }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { targets.forEach { store.delete($0) } }
    }

    static var tonight: Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
        return today > Date() ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    static var nextMonday: Date {
        let calendar = Calendar.current
        let next = calendar.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)
        return next ?? Date().addingTimeInterval(7 * 86400)
    }
}

/// Keyboard and loading shared by every reminders screen: space completes the selection, ⌫ deletes it.
struct ReminderListBehavior: ViewModifier {
    let title: String
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var store = RemindersStore.shared
    @State private var confirmDelete = false

    private var selected: [Reminder] { navigator.reminderSelection.compactMap { store.reminder(id: $0) } }

    func body(content: Content) -> some View {
        content
            .background(Color.canvas)
            .toolbar(removing: .title)
            .navigationTitle(title)
            .onKeyPress(.space) {
                guard !selected.isEmpty else { return .ignored }
                selected.forEach { store.toggleDone($0) }
                return .handled
            }
            .onDeleteCommand { if !selected.isEmpty { confirmDelete = true } }
            .confirmationDialog(selected.count > 1 ? String(localized: "Delete \(selected.count) reminders?") : String(localized: "Delete this reminder?"), isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    selected.forEach { store.delete($0) }
                    navigator.reminderSelection = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { navigator.showsQuickEntry = true } label: { Label("New Reminder", systemImage: "plus") }
                        .help("Quick entry (⌘N)")
                }
            }
            .task(id: navigator.refreshTick) {
                store.attach(session.api)
                await store.load()
            }
            .safeAreaInset(edge: .bottom) {
                if let error = store.error { errorBanner(error) }
            }
            .animation(.snappy(duration: 0.2), value: store.error)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.bad)
            Text(message).font(.callout).foregroundStyle(Color.ink).textSelection(.enabled)
            Spacer(minLength: Spacing.xs)
            Button { store.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.bad.opacity(0.4)))
        .padding(Spacing.md)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    func reminderListBehavior(title: String) -> some View { modifier(ReminderListBehavior(title: title)) }

    /// Rows dragged out of a list carry their id (`List.onMove` keeps reordering inside it).
    func reminderDragItem(_ id: String) -> some View {
        itemProvider { NSItemProvider(object: id as NSString) }
    }
}

/// Text prompt used to rename an area, a project or a heading, or to give it an emoji.
struct NamePrompt: Identifiable {
    enum Kind { case newArea, renameArea(String), areaEmoji(String), renameProject(String), projectEmoji(String), newHeading(String), renameHeading(ProjectHeading) }

    let id = UUID()
    let kind: Kind
    var text: String

    var title: String {
        switch kind {
        case .newArea: String(localized: "New Area")
        case .renameArea, .renameProject, .renameHeading: String(localized: "Rename")
        case .areaEmoji, .projectEmoji: String(localized: "Emoji")
        case .newHeading: String(localized: "New Section")
        }
    }

    var placeholder: String {
        switch kind {
        case .newArea, .renameArea: String(localized: "Area name")
        case .renameProject: String(localized: "Project name")
        case .areaEmoji, .projectEmoji: String(localized: "An emoji (⌃⌘Space)")
        case .newHeading, .renameHeading: String(localized: "Section name")
        }
    }

    var confirm: String {
        switch kind {
        case .newArea, .newHeading: String(localized: "Create")
        default: String(localized: "OK")
        }
    }

    @MainActor func commit() {
        let store = RemindersStore.shared
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .areaEmoji(let id):
            Task { await store.updateArea(id, patch: ["emoji": value.isEmpty ? .null : .string(String(value.prefix(2)))]) }
        case .projectEmoji(let id):
            Task { await store.updateProject(id, patch: ["emoji": value.isEmpty ? .null : .string(String(value.prefix(2)))]) }
        default:
            guard !value.isEmpty else { return }
            switch kind {
            case .newArea: Task { await store.createArea(title: value) }
            case .renameArea(let id): Task { await store.updateArea(id, patch: ["title": .string(value)]) }
            case .renameProject(let id): Task { await store.updateProject(id, patch: ["title": .string(value)]) }
            case .newHeading(let projectId): Task { await store.createHeading(in: projectId, title: value) }
            case .renameHeading(let heading): Task { await store.renameHeading(heading, to: value) }
            case .areaEmoji, .projectEmoji: break
            }
        }
    }
}

extension View {
    func namePrompt(_ prompt: Binding<NamePrompt?>) -> some View {
        alert(prompt.wrappedValue?.title ?? "", isPresented: Binding(get: { prompt.wrappedValue != nil }, set: { if !$0 { prompt.wrappedValue = nil } })) {
            TextField(prompt.wrappedValue?.placeholder ?? "", text: Binding(get: { prompt.wrappedValue?.text ?? "" }, set: { prompt.wrappedValue?.text = $0 }))
            Button(prompt.wrappedValue?.confirm ?? "OK") {
                prompt.wrappedValue?.commit()
                prompt.wrappedValue = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { prompt.wrappedValue = nil }
        }
    }
}
