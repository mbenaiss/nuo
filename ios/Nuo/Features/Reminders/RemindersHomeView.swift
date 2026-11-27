#if os(iOS)
import SwiftUI

/// Navigation and sheets of the Rappels tab, shared by every screen pushed on it.
@MainActor
@Observable
final class RemindersNavigator {
    /// Opens on « Aujourd'hui » with the home one step back.
    var path: [ReminderRoute] = RemindersDemo.opensHome ? [] : [.list(.today)]
    var editing: ReminderEditorTarget?
    var moving: Reminder?
    var projectEditor: ProjectEditorTarget?
    var areaEditor: AreaEditorTarget?
    var finishing: ProjectFinishRequest?
    var deleting: OrganisationDeletion?
    var showsPlaces = false

    func open(_ reminder: Reminder) { editing = ReminderEditorTarget(reminder: reminder, parsed: nil) }

    func newReminder(_ parsed: ParsedReminder? = nil) { editing = ReminderEditorTarget(reminder: nil, parsed: parsed) }

    /// Things asks what to do with the reminders still open; with none, completing needs no question.
    func requestFinish(_ project: ReminderProject, cancel: Bool) {
        let open = RemindersStore.shared.phoneOpenCount(inProject: project.id)
        if open == 0, !cancel {
            Task { await RemindersStore.shared.finishProject(project.id) }
        } else {
            finishing = ProjectFinishRequest(project: project, cancel: cancel, openCount: open)
        }
    }
}

struct ProjectFinishRequest: Identifiable {
    let project: ReminderProject
    let cancel: Bool
    let openCount: Int
    var id: String { project.id }
}

enum OrganisationDeletion: Identifiable {
    case project(ReminderProject)
    case area(ReminderArea)

    var id: String {
        switch self {
        case let .project(project): project.id
        case let .area(area): area.id
        }
    }
}

enum RemindersLayout {
    /// Leading column of icons, rings and emojis: as wide as a reminder's check circle so every title shares one edge.
    static let iconWidth: CGFloat = 24
    static let rowMinHeight: CGFloat = 44
    static let navigationRowInsets = EdgeInsets(top: Spacing.xxs, leading: CardMetrics.rowInset, bottom: Spacing.xxs, trailing: CardMetrics.rowInset)
    static let reminderRowInsets = EdgeInsets(top: Spacing.sm, leading: CardMetrics.rowInset, bottom: Spacing.sm, trailing: CardMetrics.rowInset)
    /// Rows drawn on the canvas (headers, notes, empty states) line up with the content of card rows.
    static let plainRowInsets = EdgeInsets(top: 0, leading: CardMetrics.rowInset, bottom: 0, trailing: CardMetrics.rowInset)
}

func remindersCount(_ count: Int) -> String { String(localized: "\(count) reminders") }

// MARK: Home

struct RemindersHomeView: View {
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared

    var body: some View {
        List {
            if store.hasLocationReminders, LocationAccess.shared.isDenied {
                Section {
                    LocationDeniedBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if let error = store.error, store.loaded {
                Section {
                    StaleBanner(message: error) { Task { await store.load() } }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section { bucketRow(.inbox) }
            Section {
                ForEach([ReminderBucket.today, .upcoming, .anytime, .someday]) { bucketRow($0) }
            }
            Section { bucketRow(.logbook) }

            ForEach(store.sortedAreas) { area in
                Section {
                    areaRow(area)
                    ForEach(store.openProjects(in: area.id)) { ProjectNavigationRow(project: $0) }
                }
            }
            let loose = store.openProjects(in: nil)
            if !loose.isEmpty {
                Section {
                    ForEach(loose) { ProjectNavigationRow(project: $0) }
                } header: {
                    Text("Projects")
                }
            }
            if store.loaded, store.areas.isEmpty, store.projects.isEmpty {
                Section {
                    Text("Organize your reminders into projects (a goal with an end) and areas (Work, Home…): tap +.")
                        .font(.footnote)
                        .foregroundStyle(Color.text2)
                        .listRowInsets(RemindersLayout.plainRowInsets)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.md)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Reminders")
        .refreshable { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { nav.showsPlaces = true } label: { Image(systemName: "mappin.and.ellipse") }
                    .accessibilityLabel("Places")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { nav.newReminder() } label: { Label("New reminder", systemImage: "checklist") }
                    Button { nav.projectEditor = ProjectEditorTarget(project: nil, areaId: nil) } label: {
                        Label("New project", systemImage: "circle.dashed.inset.filled")
                    }
                    Button { nav.areaEditor = AreaEditorTarget(area: nil) } label: {
                        Label("New area", systemImage: "square.stack.3d.up")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
    }

    private func bucketRow(_ bucket: ReminderBucket) -> some View {
        NavigationLink(value: ReminderRoute.list(bucket)) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: bucket.filledSymbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(bucket.tint)
                    .frame(width: RemindersLayout.iconWidth)
                Text(bucket.label).foregroundStyle(Color.ink)
                Spacer(minLength: Spacing.xs)
                if bucket == .today, store.count(.overdue) > 0 {
                    Text("\(store.count(.overdue))")
                        .font(.footnote.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.bad, in: Capsule())
                        .accessibilityLabel("\(store.count(.overdue)) overdue")
                }
                let count = store.count(in: bucket)
                if count > 0 {
                    Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(Color.text3)
                }
            }
            .frame(minHeight: RemindersLayout.rowMinHeight)
        }
        .listRowInsets(RemindersLayout.navigationRowInsets)
        .listRowBackground(Color.card)
    }

    private func areaRow(_ area: ReminderArea) -> some View {
        NavigationLink(value: ReminderRoute.area(area.id)) {
            HStack(spacing: Spacing.sm) {
                AreaGlyph(emoji: area.emoji)
                Text(area.title).font(.body.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Spacer(minLength: Spacing.xs)
                let loose = store.openReminders(inArea: area.id).count
                if loose > 0 {
                    Text("\(loose)").font(.subheadline).monospacedDigit().foregroundStyle(Color.text3)
                }
            }
            .frame(minHeight: RemindersLayout.rowMinHeight)
        }
        .listRowInsets(RemindersLayout.navigationRowInsets)
        .listRowBackground(Color.card)
        .contextMenu { AreaMenuItems(area: area) }
    }
}

struct AreaGlyph: View {
    let emoji: String?

    var body: some View {
        Group {
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 17))
            } else {
                Image(systemName: "square.stack.3d.up.fill").font(.body).foregroundStyle(Color.text2)
            }
        }
        .frame(width: RemindersLayout.iconWidth)
    }
}

/// A project in a list: progress ring, emoji and title, deadline.
struct ProjectNavigationRow: View {
    let project: ReminderProject
    @State private var store = RemindersStore.shared

    var body: some View {
        NavigationLink(value: ReminderRoute.project(project.id)) {
            HStack(spacing: Spacing.sm) {
                let progress = store.progress(project)
                ProjectProgressRing(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 18,
                                    tint: project.someday ? Color.text3 : ProjectProgressRing.defaultTint, finished: !project.isOpen)
                    .frame(width: RemindersLayout.iconWidth)
                Text(ReminderFiling.titled(project.emoji, project.title))
                    .foregroundStyle(project.isOpen ? Color.ink : Color.text2)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                if project.someday, project.isOpen {
                    Image(systemName: "archivebox").font(.footnote).foregroundStyle(Color.text3).accessibilityLabel("Someday")
                }
                if let deadline = project.deadlineDate, project.isOpen { DeadlineBadge(date: deadline) }
            }
            .frame(minHeight: RemindersLayout.rowMinHeight)
        }
        .listRowInsets(RemindersLayout.navigationRowInsets)
        .listRowBackground(Color.card)
        .contextMenu { ProjectMenuItems(project: project) }
    }
}

/// Things' flag: the date, or the days left once it is close.
struct DeadlineBadge: View {
    let date: Date
    var prominent = false

    var body: some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        let urgent = days <= 7
        Label {
            Text(text(days))
        } icon: {
            Image(systemName: "flag.fill")
        }
        .labelStyle(TightLabelStyle())
        .font(prominent ? .subheadline.weight(.semibold) : .footnote.weight(.medium))
        .foregroundStyle(urgent ? Color.bad : Color.text2)
        .lineLimit(1)
        .accessibilityLabel("Deadline \(text(days))")
    }

    private func text(_ days: Int) -> String {
        if days < 0 { return days == -1 ? String(localized: "Yesterday") : String(localized: "\(-days) d overdue") }
        if days == 0 { return String(localized: "Today") }
        if days == 1 { return String(localized: "Tomorrow") }
        if days <= 7 { return String(localized: "In \(days) d") }
        return date.formatted(Date.FormatStyle(locale: ValueFormat.locale).day().month(.abbreviated))
    }
}

// MARK: Menus

struct ProjectMenuItems: View {
    let project: ReminderProject
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared

    var body: some View {
        Button { nav.projectEditor = ProjectEditorTarget(project: project, areaId: project.areaId) } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button { nav.projectEditor = ProjectEditorTarget(project: project, areaId: project.areaId, focus: .emoji) } label: {
            Label("Change emoji", systemImage: "face.smiling")
        }
        Menu {
            Button { move(nil) } label: {
                Label("No area", systemImage: project.areaId == nil ? "checkmark" : "minus")
            }
            ForEach(store.sortedAreas) { area in
                Button { move(area.id) } label: {
                    if project.areaId == area.id {
                        Label(ReminderFiling.titled(area.emoji, area.title), systemImage: "checkmark")
                    } else {
                        Text(ReminderFiling.titled(area.emoji, area.title))
                    }
                }
            }
        } label: {
            Label("Move to area", systemImage: "square.stack.3d.up")
        }
        Button {
            Task { await store.updateProject(project.id, patch: ["someday": .bool(!project.someday)]) }
        } label: {
            Label(project.someday ? String(localized: "Remove from Someday") : String(localized: "Move to Someday"), systemImage: "archivebox")
        }
        Divider()
        if project.isOpen {
            Button { nav.requestFinish(project, cancel: false) } label: { Label("Complete project", systemImage: "checkmark.circle") }
            Button { nav.requestFinish(project, cancel: true) } label: { Label("Cancel project", systemImage: "xmark.circle") }
        } else {
            Button { Task { await store.reopenProject(project.id) } } label: { Label("Reopen project", systemImage: "arrow.uturn.backward") }
        }
        Divider()
        Button(role: .destructive) { nav.deleting = .project(project) } label: { Label("Delete", systemImage: "trash") }
    }

    private func move(_ areaId: String?) {
        Haptics.selection()
        Task { await store.updateProject(project.id, patch: ["areaId": areaId.map(JSONValue.string) ?? .null]) }
    }
}

struct AreaMenuItems: View {
    let area: ReminderArea
    @Environment(RemindersNavigator.self) private var nav

    var body: some View {
        Button { nav.areaEditor = AreaEditorTarget(area: area) } label: { Label("Rename", systemImage: "pencil") }
        Button { nav.areaEditor = AreaEditorTarget(area: area, focus: .emoji) } label: { Label("Change emoji", systemImage: "face.smiling") }
        Button { nav.projectEditor = ProjectEditorTarget(project: nil, areaId: area.id) } label: {
            Label("New project here", systemImage: "plus.circle")
        }
        Divider()
        Button(role: .destructive) { nav.deleting = .area(area) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Confirmations for completing, cancelling and deleting projects and areas, shown over any screen of the tab.
struct OrganisationDialogs: ViewModifier {
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared

    func body(content: Content) -> some View {
        @Bindable var nav = nav
        content
            .confirmationDialog(nav.finishing.map { $0.cancel ? String(localized: "Cancel “\($0.project.title)”?") : String(localized: "Complete “\($0.project.title)”?") } ?? "",
                                isPresented: Binding(get: { nav.finishing != nil }, set: { if !$0 { nav.finishing = nil } }),
                                titleVisibility: .visible, presenting: nav.finishing) { request in
                if request.openCount > 0 {
                    Button(request.cancel ? String(localized: "Also cancel open reminders") : String(localized: "Also complete open reminders")) { finish(request, keepOpen: false) }
                    Button("Keep reminders open") { finish(request, keepOpen: true) }
                } else {
                    Button("Cancel project", role: .destructive) { finish(request, keepOpen: false) }
                }
                Button("Back", role: .cancel) {}
            } message: { request in
                if request.openCount > 0 {
                    Text("\(remindersCount(request.openCount)) left in this project.")
                }
            }
            .confirmationDialog(deletionTitle, isPresented: Binding(get: { nav.deleting != nil }, set: { if !$0 { nav.deleting = nil } }),
                                titleVisibility: .visible, presenting: nav.deleting) { item in
                Button("Delete", role: .destructive) { delete(item) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                switch item {
                case let .project(project):
                    let count = store.openReminders(inProject: project.id).count + store.doneReminders(inProject: project.id).count
                    Text(count == 0 ? String(localized: "Its headings will be deleted.") : String(localized: "Its headings and its \(remindersCount(count)) will be deleted."))
                case .area:
                    Text("Its projects and reminders are kept, without an area.")
                }
            }
    }

    private var deletionTitle: String {
        switch nav.deleting {
        case let .project(project)?: String(localized: "Delete “\(project.title)”?")
        case let .area(area)?: String(localized: "Delete “\(area.title)”?")
        case nil: ""
        }
    }

    private func finish(_ request: ProjectFinishRequest, keepOpen: Bool) {
        Task { await store.finishProject(request.project.id, cancel: request.cancel, keepOpen: keepOpen) }
    }

    private func delete(_ item: OrganisationDeletion) {
        Haptics.tap()
        switch item {
        case let .project(project):
            withAnimation { nav.path.removeAll { $0 == .project(project.id) } }
            Task { await store.deleteProject(project.id) }
        case let .area(area):
            withAnimation { nav.path.removeAll { $0 == .area(area.id) } }
            Task { await store.deleteArea(area.id) }
        }
    }
}

// MARK: Rows

/// A reminder in any iPhone list: tap to edit, swipe to complete or snooze, long-press for the rest.
struct PhoneReminderRow: View {
    let reminder: Reminder
    var segment: ReminderSegment = .overdue
    var showsParent = true
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared

    var body: some View {
        ReminderRow(reminder: reminder, segment: segment, completing: store.completing.contains(reminder.id), showsParent: showsParent) {
            store.toggleDone(reminder)
        }
        .contentShape(Rectangle())
        .onTapGesture { nav.open(reminder) }
        .listRowBackground(Color.card)
        .listRowInsets(RemindersLayout.reminderRowInsets)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { store.toggleDone(reminder) } label: {
                Label(reminder.isDone ? String(localized: "Reopen") : String(localized: "Done"), systemImage: reminder.isDone ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(reminder.isDone ? Color.text2 : Color.good)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { store.delete(reminder) } label: { Label("Delete", systemImage: "trash") }
            if !reminder.isDone {
                Button { nav.moving = reminder } label: { Label("Move", systemImage: "arrow.right.circle") }
                    .tint(Color(hex: 0x3B82F6))
                Button { store.snooze(reminder, until: ReminderNotifications.tomorrowMorning()) } label: {
                    Label("Tomorrow", systemImage: "sunrise")
                }
                .tint(Color(hex: 0xF59E0B))
            }
        }
        .contextMenu {
            Button { store.toggleDone(reminder) } label: {
                Label(reminder.isDone ? String(localized: "Reopen") : String(localized: "Mark as done"), systemImage: reminder.isDone ? "arrow.uturn.backward" : "checkmark.circle")
            }
            if !reminder.isDone {
                Button { store.snooze(reminder, until: Date().addingTimeInterval(3600)) } label: { Label("In an hour", systemImage: "clock") }
                Button { store.snooze(reminder, until: ReminderNotifications.tomorrowMorning()) } label: { Label("Tomorrow 9 AM", systemImage: "sunrise") }
                Button { nav.moving = reminder } label: { Label("Move…", systemImage: "arrow.right.circle") }
                Button { Task { await store.setSomeday(reminder, !reminder.isSomeday) } } label: {
                    Label(reminder.isSomeday ? String(localized: "Remove from Someday") : String(localized: "Move to Someday"), systemImage: "archivebox")
                }
            }
            Button { nav.open(reminder) } label: { Label("Edit", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { store.delete(reminder) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct ReminderSkeletonSection: View {
    var body: some View {
        Section {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    Circle().strokeBorder(Color.chip, lineWidth: 2).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        SkeletonBar(width: [180, 140, 200, 120, 160][index], height: 12)
                        SkeletonBar(width: 90, height: 9)
                    }
                }
                .listRowInsets(RemindersLayout.reminderRowInsets)
            }
        }
        .listRowBackground(Color.card)
    }
}

// MARK: Smart lists

struct ReminderBucketView: View {
    let bucket: ReminderBucket
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared

    var body: some View {
        let groups = store.phoneGroups(bucket)
        let finished = bucket == .logbook ? store.finishedProjects : []
        List {
            if bucket == .today, store.hasLocationReminders, LocationAccess.shared.isDenied {
                Section {
                    LocationDeniedBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if !store.loaded {
                ReminderSkeletonSection()
            } else if groups.isEmpty, finished.isEmpty {
                Section {
                    empty
                        .listRowInsets(RemindersLayout.plainRowInsets)
                        .listRowBackground(Color.clear)
                }
            } else {
                if let error = store.error {
                    Section {
                        StaleBanner(message: error) { Task { await store.load() } }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if !finished.isEmpty {
                    Section {
                        ForEach(finished) { ProjectNavigationRow(project: $0) }
                    } header: {
                        PlainSectionHeader(title: String(localized: "Completed projects"))
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.reminders) { reminder in
                            PhoneReminderRow(reminder: reminder, segment: bucket.rowSegment, showsParent: group.route == nil)
                        }
                    } header: {
                        header(group)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.md)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(bucket.label)
        .refreshable { await store.load() }
        .animation(.snappy(duration: 0.3), value: groups.map(\.id))
        .safeAreaInset(edge: .bottom) {
            if bucket != .logbook {
                QuickAddBar(someday: bucket == .someday) { draft in
                    await store.create(draft) != nil
                } onDetails: { parsed in
                    nav.newReminder(parsed)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ group: PhoneReminderGroup) -> some View {
        if let route = group.route {
            Button {
                Haptics.selection()
                nav.path.append(route)
            } label: {
                HStack(spacing: Spacing.xs) {
                    if let emoji = group.emoji, !emoji.isEmpty { Text(emoji) }
                    Text(group.title).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
                    Spacer(minLength: 0)
                }
                .font(.headline)
                .foregroundStyle(Color.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)
        } else if !group.title.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(group.title).font(.title3.bold()).foregroundStyle(Color.ink)
                if let subtitle = group.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Color.text3) }
                Spacer(minLength: 0)
            }
            .textCase(nil)
        }
    }

    private var empty: some View {
        switch bucket {
        case .inbox: WorkspaceEmptyState(symbol: "tray", title: String(localized: "Inbox is empty"), message: String(localized: "Reminders with no date, project or area land here."), mascot: .done)
        case .today: WorkspaceEmptyState(symbol: "star", title: String(localized: "All done"), message: String(localized: "Add a reminder below."), mascot: .done)
        case .upcoming: WorkspaceEmptyState(symbol: "calendar", title: String(localized: "Nothing planned"), message: String(localized: "Reminders dated for the coming days appear here."), mascot: .idle)
        case .anytime: WorkspaceEmptyState(symbol: "square.stack.3d.up", title: String(localized: "Nothing to do"), message: String(localized: "Open reminders from your projects and areas appear here."), mascot: .sleep)
        case .someday: WorkspaceEmptyState(symbol: "archivebox", title: String(localized: "Nothing for someday"), message: String(localized: "Put what can wait here: use “Someday” in a reminder's details."))
        case .logbook: WorkspaceEmptyState(symbol: "book.closed", title: String(localized: "Logbook is empty"), message: String(localized: "Completed reminders and projects appear here."))
        }
    }
}

struct PlainSectionHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.headline).foregroundStyle(Color.ink).textCase(nil)
    }
}
#endif
