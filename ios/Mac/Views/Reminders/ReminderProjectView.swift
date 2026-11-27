import SwiftUI

/// A project, Things style: pie, editable title and notes, deadline, reminders under their headings, done ones folded.
struct ReminderProjectView: View {
    let projectId: String
    @Environment(MacNavigator.self) private var navigator
    @State private var store = RemindersStore.shared
    @State private var title = ""
    @State private var notes = ""
    /// The project `title` and `notes` were filled from: the view is reused when the sidebar switches projects.
    @State private var filledId: String?
    @State private var showsDone = false
    @State private var showsDeadline = false
    @State private var prompt: NamePrompt?
    @State private var confirmFinish: Bool?
    @State private var confirmDelete = false
    @State private var addingIn: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var notesFocused: Bool

    private var project: ReminderProject? { store.project(id: projectId) }
    private var list: ReminderSmartList { .project(projectId) }
    private var headings: [ProjectHeading] { store.headings(ofProject: projectId) }
    private var openCount: Int { store.openReminders(inProject: projectId).count }
    private var done: [Reminder] { store.doneReminders(inProject: projectId) }

    var body: some View {
        if let project {
            VStack(alignment: .leading, spacing: 0) {
                header(project)
                    .padding(.horizontal, ReminderMacMetrics.gutter)
                    .padding(.top, ReminderMacMetrics.headerTop)
                    .padding(.bottom, 6)
                reminderList(project)
            }
            .reminderListBehavior(title: project.title)
            .task(id: projectId) { await store.loadProject(projectId) }
            .onAppear(perform: fill)
            .onDisappear(perform: saveEdits)
            .onChange(of: projectId) { _, _ in
                saveEdits()
                fill()
            }
            .onChange(of: project.title) { _, value in if !titleFocused { title = value } }
            .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }
            .onChange(of: notesFocused) { _, focused in if !focused { saveNotes() } }
            .namePrompt($prompt)
            .confirmationDialog(confirmFinish == true ? String(localized: "Cancel the project?") : String(localized: "Complete the project?"),
                                isPresented: Binding(get: { confirmFinish != nil }, set: { if !$0 { confirmFinish = nil } }),
                                titleVisibility: .visible) {
                let cancel = confirmFinish == true
                Button(cancel ? String(localized: "Also Cancel the Reminders") : String(localized: "Mark the Reminders as Done")) { finish(cancel: cancel, keepOpen: false) }
                Button("Keep the Reminders Open") { finish(cancel: cancel, keepOpen: true) }
                Button("Back", role: .cancel) {}
            } message: {
                Text("\(openCount) reminders are still open.")
            }
            .confirmationDialog("Delete “\(project.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Project", role: .destructive) {
                    navigator.sidebar = .reminders(project.areaId.map(ReminderSmartList.area) ?? .anytime)
                    Task { await store.deleteProject(projectId) }
                }
            } message: {
                Text("Its sections and reminders are deleted with it.")
            }
        } else {
            ContentUnavailableView("Project not found", systemImage: "circle.circle", description: Text("It may have been deleted."))
                .background(Color.canvas)
        }
    }

    // MARK: Header

    private func header(_ project: ReminderProject) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                ProjectPie(progress: store.macProgress(project), size: ReminderMacMetrics.headerPie, tint: project.isOpen ? Color.accent : Color.good)
                if let emoji = project.emoji, !emoji.isEmpty {
                    Button { prompt = NamePrompt(kind: .projectEmoji(projectId), text: emoji) } label: {
                        Text(emoji).font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .help("Change emoji")
                }
                TextField("New project", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .focused($titleFocused)
                    .onSubmit { saveTitle(); notesFocused = true }
                Spacer(minLength: Spacing.xs)
                deadlineButton(project)
                actionsMenu(project)
            }
            TextField("Notes", text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(Color.text2)
                .lineLimit(1...8)
                .focused($notesFocused)
                // Leading edge of the title text: pie, gap and (when set) emoji.
                .padding(.leading, ReminderMacMetrics.headerPie + Spacing.sm)
            if !project.isOpen {
                finishedBanner(project)
            } else {
                InlineReminderEntry(destination: .project(projectId, heading: nil), placeholder: String(localized: "New reminder in this project…"))
            }
        }
    }

    @ViewBuilder
    private func deadlineButton(_ project: ReminderProject) -> some View {
        let days = store.macDaysLeft(project)
        Button { showsDeadline = true } label: {
            if let date = project.deadlineDate {
                Label(ProjectDeadlineText.short(date, daysLeft: days), systemImage: "flag.fill")
                    .foregroundStyle((days ?? 1) <= 0 ? Color.bad : Color.text2)
            } else {
                Label("Deadline", systemImage: "flag")
                    .foregroundStyle(Color.text2)
            }
        }
        .buttonStyle(.borderless)
        .help("Project deadline")
        .popover(isPresented: $showsDeadline, arrowEdge: .bottom) {
            DeadlinePicker(initial: project.deadlineDate) { date in
                Task { await store.updateProject(projectId, patch: ["deadline": date.map { .string(ProjectDeadlineText.iso($0)) } ?? .null]) }
                showsDeadline = false
            }
        }
    }

    private func actionsMenu(_ project: ReminderProject) -> some View {
        Menu {
            Button("Add a Section") { prompt = NamePrompt(kind: .newHeading(projectId), text: "") }
            Button(project.emoji == nil ? String(localized: "Add an Emoji…") : String(localized: "Change Emoji…")) {
                prompt = NamePrompt(kind: .projectEmoji(projectId), text: project.emoji ?? "")
            }
            Menu("Move to Area") { ProjectAreaMenu(project: project) }
            Button(project.someday ? String(localized: "Take Out of “Someday”") : String(localized: "File under “Someday”")) {
                Task { await store.updateProject(projectId, patch: ["someday": .bool(!project.someday)]) }
            }
            Divider()
            if project.isOpen {
                Button("Complete Project") { requestFinish(cancel: false) }
                Button("Cancel Project") { requestFinish(cancel: true) }
            } else {
                Button("Reopen Project") { Task { await store.reopenProject(projectId) } }
            }
            Divider()
            Button("Delete Project…", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project actions")
    }

    private func finishedBanner(_ project: ReminderProject) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: project.status == .cancelled ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(project.status == .cancelled ? Color.text3 : Color.good)
            Text(finishedLabel(project)).font(.callout.weight(.semibold)).foregroundStyle(Color.ink)
            Spacer()
            Button("Reopen") { Task { await store.reopenProject(projectId) } }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 9)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func finishedLabel(_ project: ReminderProject) -> String {
        let cancelled = project.status == .cancelled
        guard let date = project.doneAt else { return cancelled ? String(localized: "Cancelled") : String(localized: "Completed") }
        let day = date.formatted(Date.FormatStyle(locale: .current).day().month(.wide))
        return cancelled ? String(localized: "Cancelled on \(day)") : String(localized: "Completed on \(day)")
    }

    // MARK: List

    private func reminderList(_ project: ReminderProject) -> some View {
        @Bindable var navigator = navigator
        let loose = store.macOpenReminders(inProject: projectId, heading: nil)
        return List(selection: $navigator.reminderSelection) {
            ForEach(loose) { row($0) }
                .onMove { store.macMove(loose, from: $0, to: $1) }
            ForEach(headings) { heading in
                headingSection(heading, first: loose.isEmpty && heading.id == headings.first?.id)
            }
            if !done.isEmpty { doneSection }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.loaded && loose.isEmpty && headings.isEmpty && done.isEmpty {
                WorkspaceEmptyState(symbol: "circle.circle", title: String(localized: "Empty project"), message: String(localized: "Add a reminder above, or a section from the ⋯ menu."))
                    .padding(.bottom, 80)
            }
        }
    }

    @ViewBuilder
    private func headingSection(_ heading: ProjectHeading, first: Bool) -> some View {
        let items = store.macOpenReminders(inProject: projectId, heading: heading.id)
        HeadingTitle(heading: heading, first: first, onAdd: { addingIn = heading.id }) { ids in
            store.macMove(ids, to: .project(projectId, heading: heading.id))
        }
        .contextMenu {
            Button("Add a Reminder") { addingIn = heading.id }
            Button("Rename…") { prompt = NamePrompt(kind: .renameHeading(heading), text: heading.title) }
            Divider()
            Button("Delete Section", role: .destructive) { Task { await store.deleteHeading(heading) } }
        }
        ForEach(items) { row($0) }
            .onMove { store.macMove(items, from: $0, to: $1) }
        if addingIn == heading.id {
            InlineReminderEntry(destination: .project(projectId, heading: heading.id), placeholder: String(localized: "New reminder in “\(heading.title)”…"),
                                autofocus: true)
                .onExitCommand { addingIn = nil }
                .listRowSeparator(.hidden)
                .selectionDisabled()
                .padding(.vertical, 4)
        }
    }

    private var doneSection: some View {
        Group {
            Button {
                withAnimation(.snappy) { showsDone.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(showsDone ? 90 : 0))
                    Text("Done (\(done.count))").font(.callout.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Color.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, ReminderMacMetrics.groupGap)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            if showsDone {
                ForEach(done) { row($0) }
            }
        }
    }

    private func row(_ reminder: Reminder) -> some View {
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

    // MARK: Editing

    private func fill() {
        filledId = projectId
        title = project?.title ?? ""
        notes = project?.notes ?? ""
        if navigator.focusProjectTitle == projectId {
            navigator.focusProjectTitle = nil
            titleFocused = true
        }
    }

    private func saveEdits() {
        saveTitle()
        saveNotes()
    }

    private func saveTitle() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = filledId, let project = store.project(id: id) else { return }
        guard !value.isEmpty else { title = project.title; return }
        if value != project.title { Task { await store.updateProject(id, patch: ["title": .string(value)]) } }
    }

    private func saveNotes() {
        let value = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = filledId, let project = store.project(id: id), value != (project.notes ?? "") else { return }
        Task { await store.updateProject(id, patch: ["notes": value.isEmpty ? .null : .string(value)]) }
    }

    private func requestFinish(cancel: Bool) {
        if openCount > 0 { confirmFinish = cancel } else { finish(cancel: cancel, keepOpen: false) }
    }

    private func finish(cancel: Bool, keepOpen: Bool) {
        Task { await store.finishProject(projectId, cancel: cancel, keepOpen: keepOpen) }
    }
}

/// A heading of a project: drop reminders on it to file them under it.
private struct HeadingTitle: View {
    let heading: ProjectHeading
    let first: Bool
    let onAdd: () -> Void
    let onDrop: ([String]) -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        ReminderGroupTitle(title: heading.title, tint: Color.accentInk, first: first) {
            Button(action: onAdd) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.text2)
                .opacity(hovering ? 1 : 0)
                .help("Add a reminder in this section")
        }
        .onHover { hovering = $0 }
        .background(targeted ? Color.accentSoft.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { ids, _ in
            onDrop(ids)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// « Déplacer vers le domaine » of a project, shared by the project menu and the sidebar.
struct ProjectAreaMenu: View {
    let project: ReminderProject
    @State private var store = RemindersStore.shared

    var body: some View {
        Button("No area") { move(nil) }.disabled(project.areaId == nil)
        Divider()
        ForEach(store.sortedAreas) { area in
            Button(RemindersStore.macLabel(area.title, emoji: area.emoji)) { move(area.id) }
                .disabled(project.areaId == area.id)
        }
    }

    private func move(_ areaId: String?) {
        Task { await store.updateProject(project.id, patch: ["areaId": areaId.map(JSONValue.string) ?? .null]) }
    }
}

private struct DeadlinePicker: View {
    let initial: Date?
    let onPick: (Date?) -> Void
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Deadline").font(.headline)
            DatePicker("Deadline", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if initial != nil {
                    Button("Delete", role: .destructive) { onPick(nil) }
                }
                Spacer()
                Button("OK") { onPick(date) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.md)
        .frame(width: 260)
        .onAppear { date = initial ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date() }
    }
}
