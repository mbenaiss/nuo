#if os(iOS)
import SwiftUI

/// A project like in Things: progress, notes, deadline, reminders under headings, finished ones folded away.
struct ProjectScreen: View {
    let projectId: String
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared
    @State private var notes = ""
    @FocusState private var notesFocused: Bool
    @State private var showsDone = false
    @State private var quickHeading: String?
    @State private var focusQuickAdd = 0
    @State private var headingPrompt: HeadingPrompt?
    @State private var headingTitle = ""

    private enum HeadingPrompt: Identifiable {
        case new
        case rename(ProjectHeading)
        var id: String {
            switch self {
            case .new: "new"
            case let .rename(heading): heading.id
            }
        }
    }

    var body: some View {
        Group {
            if let project = store.project(id: projectId) {
                content(project)
            } else if store.loaded {
                WorkspaceEmptyState(symbol: "questionmark.folder", title: String(localized: "Project not found"), message: String(localized: "It may have been deleted."))
                    .frame(maxHeight: .infinity)
                    .background(Color.canvas)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas)
            }
        }
        .task(id: projectId) { await store.loadProject(projectId) }
    }

    private func content(_ project: ReminderProject) -> some View {
        let sections = store.phoneSections(ofProject: project.id)
        let done = store.doneReminders(inProject: project.id)
        let isEmpty = sections.allSatisfy { $0.reminders.isEmpty } && sections.count == 1
        return List {
            Section { header(project) }
            if !project.isOpen {
                Section { finishedBanner(project) }
            }
            ForEach(sections) { section in
                if section.heading != nil || !section.reminders.isEmpty {
                    Section {
                        ForEach(section.reminders) { reminder in
                            PhoneReminderRow(reminder: reminder, segment: .overdue, showsParent: false)
                        }
                        .onMove { store.phoneMove(section.reminders, from: $0, to: $1) }
                    } header: {
                        if let heading = section.heading { headingHeader(heading, project: project) }
                    }
                }
            }
            if isEmpty {
                Section {
                    WorkspaceEmptyState(symbol: "checklist", title: String(localized: "No reminders"), message: project.isOpen ? String(localized: "Add the first one below.") : nil)
                        .listRowInsets(RemindersLayout.plainRowInsets)
                        .listRowBackground(Color.clear)
                }
            }
            if !done.isEmpty {
                Section {
                    Button {
                        Haptics.selection()
                        withAnimation(.snappy) { showsDone.toggle() }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(Color.text3)
                                .frame(width: RemindersLayout.iconWidth)
                            Text("Completed (\(done.count))").foregroundStyle(Color.text2)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.text3)
                                .rotationEffect(.degrees(showsDone ? 90 : 0))
                        }
                        .frame(minHeight: RemindersLayout.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(RemindersLayout.navigationRowInsets)
                    .listRowBackground(Color.card)
                    if showsDone {
                        ForEach(done) { PhoneReminderRow(reminder: $0, segment: .done, showsParent: false) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.md)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(ReminderFiling.titled(project.emoji, project.title))
        .refreshable { await store.loadProject(project.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if project.isOpen {
                        Button { prompt(.new) } label: { Label("Add heading", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Divider()
                    }
                    ProjectMenuItems(project: project)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Project actions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if project.isOpen {
                let heading = quickHeading.flatMap { id in store.headings(ofProject: project.id).first { $0.id == id } }
                QuickAddBar(destination: .project(project.id, heading: heading?.id),
                            targetLabel: heading.map { String(localized: "Under “\($0.title)”") },
                            onClearTarget: { withAnimation(.snappy) { quickHeading = nil } },
                            focusRequest: focusQuickAdd) { draft in
                    await store.create(draft) != nil
                } onDetails: { parsed in
                    nav.newReminder(parsed)
                }
            }
        }
        .alert(headingPrompt.map { if case .new = $0 { String(localized: "New Heading") } else { String(localized: "Rename Heading") } } ?? "",
               isPresented: Binding(get: { headingPrompt != nil }, set: { if !$0 { headingPrompt = nil } })) {
            TextField("Heading", text: $headingTitle)
            Button("Cancel", role: .cancel) {}
            Button(headingPrompt.map { if case .new = $0 { String(localized: "Add") } else { String(localized: "Rename") } } ?? String(localized: "OK")) { commitHeading(project) }
        } message: {
            Text("Headings split a project into stages.")
        }
        .onAppear { if !notesFocused { notes = project.notes ?? "" } }
        .onChange(of: project.notes) { _, value in if !notesFocused { notes = value ?? "" } }
        .onChange(of: notesFocused) { _, focused in if !focused { saveNotes(project) } }
        .onDisappear { saveNotes(project) }
    }

    private func header(_ project: ReminderProject) -> some View {
        let progress = store.progress(project)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                ProjectProgressRing(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 22,
                                    tint: project.someday ? Color.text3 : ProjectProgressRing.defaultTint, finished: !project.isOpen)
                    .frame(width: RemindersLayout.iconWidth)
                Text(progress.total == 0 ? String(localized: "No reminders") : String(localized: "\(progress.done) of \(progress.total) completed"))
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                    .monospacedDigit()
                Spacer(minLength: Spacing.xs)
                if project.someday {
                    Label("Someday", systemImage: "archivebox")
                        .labelStyle(TightLabelStyle())
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.text2)
                }
                if let deadline = project.deadlineDate { DeadlineBadge(date: deadline, prominent: true) }
            }
            TextField("Notes", text: $notes, axis: .vertical)
                .font(.body)
                .foregroundStyle(Color.text2)
                .focused($notesFocused)
                .lineLimit(1...12)
        }
        .padding(.bottom, Spacing.xs)
        .listRowInsets(RemindersLayout.plainRowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func finishedBanner(_ project: ReminderProject) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: project.status == .cancelled ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(project.status == .cancelled ? Color.text3 : Color.good)
                .frame(width: RemindersLayout.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.status == .cancelled ? String(localized: "Project canceled") : String(localized: "Project completed")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                if let doneAt = project.doneAt {
                    Text(doneAt.formatted(Date.FormatStyle(locale: ValueFormat.locale).day().month(.wide).year()))
                        .font(.footnote).foregroundStyle(Color.text2)
                }
            }
            Spacer()
            Button("Reopen") { Task { await store.reopenProject(project.id) } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(.vertical, Spacing.xxs)
        .listRowInsets(RemindersLayout.reminderRowInsets)
        .listRowBackground(Color.card)
    }

    private func headingHeader(_ heading: ProjectHeading, project: ReminderProject) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(heading.title)
                .font(.headline)
                .foregroundStyle(Color.accentInk)
                .lineLimit(1)
            Spacer(minLength: Spacing.xs)
            if project.isOpen {
                Menu {
                    Button {
                        quickHeading = heading.id
                        focusQuickAdd += 1
                    } label: { Label("Add a reminder here", systemImage: "plus") }
                    Button { prompt(.rename(heading)) } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) {
                        if quickHeading == heading.id { quickHeading = nil }
                        Task { await store.deleteHeading(heading) }
                    } label: { Label("Delete heading", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Heading actions")
            }
        }
        .textCase(nil)
    }

    private func prompt(_ prompt: HeadingPrompt) {
        if case let .rename(heading) = prompt { headingTitle = heading.title } else { headingTitle = "" }
        headingPrompt = prompt
    }

    private func commitHeading(_ project: ReminderProject) {
        let title = headingTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let prompt = headingPrompt else { return }
        Task {
            switch prompt {
            case .new: await store.createHeading(in: project.id, title: title)
            case let .rename(heading): await store.renameHeading(heading, to: title)
            }
        }
    }

    private func saveNotes(_ project: ReminderProject) {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != (store.project(id: project.id)?.notes ?? "") else { return }
        Task { await store.updateProject(project.id, patch: ["notes": clean.isEmpty ? .null : .string(clean)]) }
    }
}

/// An area: its projects, then the reminders filed directly in it.
struct AreaScreen: View {
    let areaId: String
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared

    var body: some View {
        if let area = store.area(id: areaId) {
            content(area)
        } else {
            WorkspaceEmptyState(symbol: "square.stack.3d.up.slash", title: String(localized: "Area not found"), message: String(localized: "It may have been deleted."))
                .frame(maxHeight: .infinity)
                .background(Color.canvas)
        }
    }

    private func content(_ area: ReminderArea) -> some View {
        let projects = store.openProjects(in: area.id)
        let loose = store.openReminders(inArea: area.id)
        return List {
            if !projects.isEmpty {
                Section {
                    ForEach(projects) { ProjectNavigationRow(project: $0) }
                } header: {
                    PlainSectionHeader(title: String(localized: "Projects"))
                }
            }
            if !loose.isEmpty {
                Section {
                    ForEach(loose) { PhoneReminderRow(reminder: $0, segment: .overdue, showsParent: false) }
                        .onMove { store.phoneMove(loose, from: $0, to: $1) }
                } header: {
                    if !projects.isEmpty { PlainSectionHeader(title: String(localized: "Reminders")) }
                }
            }
            if projects.isEmpty, loose.isEmpty {
                Section {
                    WorkspaceEmptyState(symbol: "square.stack.3d.up", title: String(localized: "Empty area"),
                                        message: String(localized: "Add a reminder below, or a project with the ⋯ menu."))
                        .listRowInsets(RemindersLayout.plainRowInsets)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.md)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(ReminderFiling.titled(area.emoji, area.title))
        .refreshable { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { AreaMenuItems(area: area) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Area actions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            QuickAddBar(destination: .area(area.id)) { draft in
                await store.create(draft) != nil
            } onDetails: { parsed in
                nav.newReminder(parsed)
            }
        }
    }
}
#endif
