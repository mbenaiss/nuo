import SwiftUI

/// A smart list (Boîte de réception, Aujourd'hui…), Things style: big title, inline natural-language entry,
/// groups, checkbox to complete. Areas and projects have their own screens.
struct ReminderListView: View {
    let list: ReminderSmartList
    @Environment(MacNavigator.self) private var navigator
    @State private var store = RemindersStore.shared

    private var groups: [ReminderDayGroup] { store.macGroups(list) }

    var body: some View {
        switch list {
        case let .project(id): ReminderProjectView(projectId: id)
        case let .area(id): ReminderAreaView(areaId: id)
        default: smartList
        }
    }

    private var smartList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if list != .logbook { InlineReminderEntry(someday: list == .someday) }
            }
            .padding(.horizontal, ReminderMacMetrics.gutter)
            .padding(.top, ReminderMacMetrics.headerTop)
            .padding(.bottom, 6)
            reminderList
        }
        .reminderListBehavior(title: list.title)
    }

    private var reminderList: some View {
        @Bindable var navigator = navigator
        let finished = list == .logbook ? store.finishedProjects : []
        return List(selection: $navigator.reminderSelection) {
            if !finished.isEmpty {
                ReminderGroupTitle(title: String(localized: "Finished projects"), first: true)
                ForEach(finished) { project in
                    FinishedProjectRow(project: project) { navigator.sidebar = .reminders(.project(project.id)) }
                        .selectionDisabled()
                }
            }
            ForEach(groups) { group in
                if !group.title.isEmpty {
                    ReminderGroupTitle(title: group.title, subtitle: group.subtitle, tint: group.id == "overdue" ? Color.bad : Color.ink,
                                       first: finished.isEmpty && group.id == groups.first?.id)
                }
                ForEach(group.reminders) { reminder in
                    row(reminder)
                }
                .onMove(perform: list.isReorderable ? { store.macMove(group.reminders, from: $0, to: $1) } : nil)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.loaded && groups.isEmpty && finished.isEmpty { empty.padding(.bottom, 80) }
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: list.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(list.tint)
            Text(list.title).font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink)
            Spacer()
            if list == .today {
                Text(Date().formatted(Date.FormatStyle(locale: .current).weekday(.wide).day().month(.wide)).capitalized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch list {
        case .inbox: WorkspaceEmptyState(symbol: "tray", title: String(localized: "Empty inbox"), message: String(localized: "Reminders without a project or area land here."), mascot: .done)
        case .today: WorkspaceEmptyState(symbol: "star", title: String(localized: "All done"), message: String(localized: "Type (in French) “Appeler le garage demain 9h” above."), mascot: .done)
        case .upcoming: WorkspaceEmptyState(symbol: "calendar", title: String(localized: "Nothing planned"), message: String(localized: "Reminders dated on the following days appear here."), mascot: .idle)
        case .anytime: WorkspaceEmptyState(symbol: "square.stack", title: String(localized: "Nothing to do"), message: String(localized: "Everything that isn't filed under “Someday”."), mascot: .sleep)
        case .someday: WorkspaceEmptyState(symbol: "archivebox", title: String(localized: "Nothing for someday"), message: String(localized: "File here what can wait."))
        case .logbook: WorkspaceEmptyState(symbol: "book.closed", title: String(localized: "Empty logbook"), message: String(localized: "Completed reminders end up here."))
        case .area, .project: EmptyView()
        }
    }
}

private struct FinishedProjectRow: View {
    let project: ReminderProject
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: project.status == .cancelled ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(project.status == .cancelled ? Color.text3 : Color.good)
                    .frame(width: ReminderMacMetrics.checkbox)
                Text(RemindersStore.macLabel(project.title, emoji: project.emoji))
                    .foregroundStyle(Color.text2)
                    .strikethrough(project.status == .cancelled, color: Color.text3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let date = project.doneAt {
                    Text(date.formatted(Date.FormatStyle(locale: .current).day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(Color.text3)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// « Appeler le garage demain 9h #lumen !! » with the parsed date, list and priority shown as chips while typing.
struct InlineReminderEntry: View {
    var destination: ReminderDestination?
    var someday = false
    var placeholder = String(localized: "New reminder… (in French) “demain 9h !!”")
    var autofocus = false
    var onAdded: (() -> Void)?
    @State private var text = ""
    @State private var dictationKey = "reminder-\(UUID().uuidString)"
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var parsed: ParsedReminder {
        let store = RemindersStore.shared
        return ReminderParser.parse(text, places: PlacesStore.shared.places, projects: store.projects.filter(\.isOpen), areas: store.areas)
    }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let parsed = self.parsed
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accent)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($focused)
                    .onSubmit(submit)
                    .disabled(sending)
                DictationButton(key: dictationKey, text: $text, size: 24, compact: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Color.accent.opacity(0.6) : Color.line))
            if !trimmed.isEmpty, parsed.hasExtras {
                ParsedPreview(parsed: parsed).transition(.opacity)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(Color.bad) }
        }
        .animation(.snappy(duration: 0.2), value: parsed.hasExtras && !trimmed.isEmpty)
        .onAppear {
            if let draft = RemindersDemo.quickAddDraft { text = draft }
            if autofocus { focused = true }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !sending else { return }
        let result = parsed
        sending = true
        Task {
            var draft = ReminderDraft(title: result.title, notes: nil, dueAt: result.dueAt, repeat: result.repeat,
                                      list: result.list, priority: result.priority > 0 ? result.priority : nil,
                                      placeId: result.place?.id, placeTrigger: result.placeTrigger)
            switch result.destination ?? destination {
            case let .area(id)?: draft.areaId = id
            case let .project(id, heading)?: (draft.projectId, draft.headingId) = (id, heading)
            case .inbox?, nil: break
            }
            if someday { draft.someday = true }
            let store = RemindersStore.shared
            let ok = await store.create(draft) != nil
            sending = false
            if ok {
                failure = nil
                text = ""
                onAdded?()
            } else {
                // Shown here, next to the text kept for another try, rather than in the list's banner.
                failure = store.error ?? String(localized: "Reminder not saved.")
                store.clearError()
            }
            focused = true
        }
    }
}

/// ⌘N outside the bots: a small floating entry, like Things' Quick Entry.
struct QuickEntryPanel: View {
    var destination: ReminderDestination?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Reminder").font(.headline)
                Spacer()
                if let label = destinationLabel { Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            InlineReminderEntry(destination: destination, autofocus: true) { dismiss() }
            Text("Dates, repeats, !priority and places are understood: “tous les lundis 8h”, “en arrivant à la maison”.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var destinationLabel: String? {
        let store = RemindersStore.shared
        switch destination {
        case let .project(id, _)?: return store.project(id: id).map { String(localized: "In \(RemindersStore.macLabel($0.title, emoji: $0.emoji))") }
        case let .area(id)?: return store.area(id: id).map { String(localized: "In \(RemindersStore.macLabel($0.title, emoji: $0.emoji))") }
        default: return nil
        }
    }
}

/// Detail column of the reminders: the shared editor for one reminder, a summary for several.
struct ReminderInspector: View {
    @Environment(MacNavigator.self) private var navigator
    @State private var store = RemindersStore.shared

    var body: some View {
        let ids = navigator.reminderSelection
        if ids.count == 1, let id = ids.first, let reminder = store.reminder(id: id) {
            NavigationStack {
                ReminderDetailSheet(target: ReminderEditorTarget(reminder: reminder, parsed: nil), lists: store.lists)
                    .formStyle(.grouped)
                    .environment(\.isEmbeddedEditor, true)
            }
            // Keyed on the id only: the editor saves as you type, a key on updatedAt would rebuild it and drop focus.
            .id(reminder.id)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) reminders", systemImage: "checklist",
                                   description: Text("Space to mark them as done, right-click to snooze or move them."))
        } else {
            ContentUnavailableView("No reminder selected", systemImage: "checklist",
                                   description: Text("⌘N for quick entry, in natural language."))
        }
    }
}
