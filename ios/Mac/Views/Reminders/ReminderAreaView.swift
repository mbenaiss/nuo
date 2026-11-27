import SwiftUI

/// An area (« domaine »): its open projects, then the reminders filed directly in it.
struct ReminderAreaView: View {
    let areaId: String
    @Environment(MacNavigator.self) private var navigator
    @State private var store = RemindersStore.shared
    @State private var prompt: NamePrompt?
    @State private var confirmDelete = false

    private var area: ReminderArea? { store.area(id: areaId) }
    private var list: ReminderSmartList { .area(areaId) }

    var body: some View {
        if let area {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    header(area)
                    InlineReminderEntry(destination: .area(areaId), placeholder: String(localized: "New reminder in “\(area.title)”…"))
                }
                .padding(.horizontal, ReminderMacMetrics.gutter)
                .padding(.top, ReminderMacMetrics.headerTop)
                .padding(.bottom, 6)
                reminderList
            }
            .reminderListBehavior(title: area.title)
            .namePrompt($prompt)
            .confirmationDialog("Delete “\(area.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Area", role: .destructive) {
                    navigator.sidebar = .reminders(.anytime)
                    Task { await store.deleteArea(areaId) }
                }
            } message: {
                Text("Its projects and reminders are kept, without an area.")
            }
        } else {
            ContentUnavailableView("Area not found", systemImage: "square.stack.3d.up", description: Text("It may have been deleted."))
                .background(Color.canvas)
        }
    }

    private func header(_ area: ReminderArea) -> some View {
        HStack(spacing: 12) {
            Button { prompt = NamePrompt(kind: .areaEmoji(areaId), text: area.emoji ?? "") } label: {
                if let emoji = area.emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 26))
                } else {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.text2)
                }
            }
            .buttonStyle(.plain)
            .help("Change emoji")
            Text(area.title).font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink)
            Spacer()
            Menu {
                Button("New Project in This Area") { navigator.newProject(areaId: areaId) }
                Button("Rename…") { prompt = NamePrompt(kind: .renameArea(areaId), text: area.title) }
                Divider()
                Button("Delete Area…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Area actions")
        }
    }

    private var reminderList: some View {
        @Bindable var navigator = navigator
        let projects = store.openProjects(in: areaId)
        let loose = store.openReminders(inArea: areaId)
        return List(selection: $navigator.reminderSelection) {
            if !projects.isEmpty {
                ReminderGroupTitle(title: String(localized: "Projects"), first: true)
                ForEach(projects) { project in
                    AreaProjectRow(project: project) { navigator.sidebar = .reminders(.project(project.id)) }
                        .selectionDisabled()
                }
            }
            if !loose.isEmpty {
                if !projects.isEmpty { ReminderGroupTitle(title: String(localized: "Reminders")) }
                ForEach(loose) { reminder in
                    MacReminderRow(reminder: reminder, list: list, completing: store.completing.contains(reminder.id)) {
                        store.toggleDone(reminder)
                    }
                    .padding(.vertical, ReminderMacMetrics.rowVertical)
                    .tag(reminder.id)
                    .reminderDragItem(reminder.id)
                    .contextMenu {
                        ReminderContextMenu(reminder: reminder, targets: navigator.reminderSelection.contains(reminder.id)
                            ? navigator.reminderSelection.compactMap { store.reminder(id: $0) } : [reminder])
                    }
                }
                .onMove { store.macMove(loose, from: $0, to: $1) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.loaded && projects.isEmpty && loose.isEmpty {
                WorkspaceEmptyState(symbol: "square.stack.3d.up", title: String(localized: "Empty area"), message: String(localized: "Add a reminder above or a project (⌥⌘N)."))
                    .padding(.bottom, 80)
            }
        }
    }
}

private struct AreaProjectRow: View {
    let project: ReminderProject
    let open: () -> Void
    @State private var store = RemindersStore.shared

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ProjectPie(progress: store.macProgress(project))
                    .frame(width: ReminderMacMetrics.checkbox)
                Text(RemindersStore.macLabel(project.title, emoji: project.emoji))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if project.someday {
                    Image(systemName: "archivebox").font(.caption).foregroundStyle(Color.text3).help("Someday")
                }
                Spacer(minLength: 8)
                if let date = project.deadlineDate {
                    let days = store.macDaysLeft(project)
                    Label(ProjectDeadlineText.short(date, daysLeft: days), systemImage: "flag.fill")
                        .font(.caption)
                        .labelStyle(TightLabelStyle())
                        .foregroundStyle((days ?? 1) <= 0 ? Color.bad : Color.text2)
                }
                let open = store.openReminders(inProject: project.id).count
                if open > 0 {
                    Text("\(open)").font(.callout).monospacedDigit().foregroundStyle(Color.text3)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
