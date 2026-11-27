import SwiftUI

private enum RepeatChoice: String, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, monthly, yearly, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "Never")
        case .daily: String(localized: "Every day")
        case .weekdays: String(localized: "Weekdays")
        case .weekly: String(localized: "Every week")
        case .monthly: String(localized: "Every month")
        case .yearly: String(localized: "Every year")
        case .custom: String(localized: "Custom")
        }
    }

    init(rule: String?) {
        guard let rule else { self = .none; return }
        switch rule {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default:
            let fields = rule.split(separator: " ").map(String.init)
            guard fields.count == 5 else { self = .custom; return }
            switch (fields[2], fields[3], fields[4]) {
            case ("*", "*", "*"): self = .daily
            case ("*", "*", "1-5"), ("*", "*", "1,2,3,4,5"): self = .weekdays
            case let ("*", "*", days) where !days.contains(",") && !days.contains("-"): self = .weekly
            case let (day, "*", "*") where Int(day) != nil: self = .monthly
            case let (day, month, "*") where Int(day) != nil && Int(month) != nil: self = .yearly
            default: self = .custom
            }
        }
    }

    /// Cron anchored on the due date (time, weekday, day of month).
    func rule(due: Date?, original: String?) -> String? {
        let calendar = Calendar.current
        guard let due else {
            switch self {
            case .none: return nil
            case .daily: return "daily"
            case .weekdays: return "0 9 * * 1-5"
            case .weekly: return "weekly"
            case .monthly: return "monthly"
            case .yearly: return "yearly"
            case .custom: return original
            }
        }
        let parts = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: due)
        let m = parts.minute ?? 0, h = parts.hour ?? 9
        switch self {
        case .none: return nil
        case .daily: return "\(m) \(h) * * *"
        case .weekdays: return "\(m) \(h) * * 1-5"
        case .weekly: return "\(m) \(h) * * \((parts.weekday ?? 1) - 1)"
        case .monthly: return "\(m) \(h) \(parts.day ?? 1) * *"
        case .yearly: return "\(m) \(h) \(parts.day ?? 1) \(parts.month ?? 1) *"
        case .custom: return original
        }
    }
}

extension EnvironmentValues {
    /// Set by a host that shows the editor inline (the Mac inspector): no Cancel/OK, changes are saved as they happen.
    @Entry var isEmbeddedEditor = false
}

struct ReminderDetailSheet: View {
    let target: ReminderEditorTarget
    let lists: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEmbeddedEditor) private var isEmbedded
    @State private var autosave: Task<Void, Never>?
    @State private var store = RemindersStore.shared
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var due = Date()
    @State private var repeatChoice: RepeatChoice = .none
    @State private var list = "inbox"
    @State private var priority = 0
    @State private var place: PlaceSelection?
    @State private var showsPlacePicker = false
    @State private var destination: ReminderDestination = .inbox
    @State private var someday = false
    @State private var checklist: [ChecklistItem] = []
    @State private var showsDestinationPicker = false
    @State private var saving = false
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    private var original: Reminder? { target.reminder }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.title3.weight(.semibold))
                        .focused($titleFocused)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...10)
                        .foregroundStyle(Color.text2)
                }
                .listRowBackground(Color.card)

                ReminderChecklistSection(items: $checklist) {
                    if let original { Task { await store.setChecklist(original, checklist) } }
                }

                Section {
                    Button { showsDestinationPicker = true } label: {
                        HStack(spacing: Spacing.sm) {
                            Label("In", systemImage: destinationSymbol).foregroundStyle(Color.ink)
                            Spacer(minLength: Spacing.xs)
                            Text(ReminderFiling.label(destination, store: store))
                                .foregroundStyle(destination == .inbox ? Color.text3 : Color.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Toggle(isOn: $someday) {
                        Label("Someday", systemImage: "archivebox").foregroundStyle(Color.ink)
                    }
                } footer: {
                    if someday { Text("It leaves “Anytime” and waits in “Someday”.") }
                }
                .listRowBackground(Color.card)

                Section {
                    Toggle(isOn: $hasDate.animation(.snappy)) {
                        Label("Date", systemImage: "calendar").foregroundStyle(Color.ink)
                    }
                    if hasDate {
                        DatePicker("When", selection: $due, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .environment(\.locale, ValueFormat.locale)
                        quickDates
                    }
                    Picker(selection: $repeatChoice) {
                        ForEach(RepeatChoice.allCases.filter { $0 != .custom || original?.repeat != nil }) { choice in
                            Text(choice == .custom ? RepeatText.describe(original?.repeat ?? "") : choice.label).tag(choice)
                        }
                    } label: {
                        Label("Repeat", systemImage: "repeat").foregroundStyle(Color.ink)
                    }
                    if repeatChoice != .none, let rule = repeatChoice.rule(due: hasDate ? due : nil, original: original?.repeat) {
                        Text(RepeatText.describe(rule)).font(.footnote).foregroundStyle(Color.text2)
                    }
                    Button { showsPlacePicker = true } label: {
                        HStack {
                            Label("Place", systemImage: "mappin.and.ellipse").foregroundStyle(Color.ink)
                            Spacer()
                            if let place {
                                PlaceChip(name: place.place.name, trigger: place.trigger, compact: false)
                            } else {
                                Text("None").foregroundStyle(Color.text3)
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.card)

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Priority", systemImage: "flag").foregroundStyle(Color.ink)
                        Picker("Priority", selection: $priority) {
                            Text("None").tag(0)
                            Text("!").tag(1)
                            Text("!!").tag(2)
                            Text("!!!").tag(3)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.card)

                if let original {
                    Section {
                        Button {
                            store.toggleDone(original)
                            dismiss()
                        } label: {
                            Label(original.isDone ? String(localized: "Reopen") : String(localized: "Mark as done"), systemImage: original.isDone ? "arrow.uturn.backward" : "checkmark.circle")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } footer: {
                        Text("Created \(original.createdAt.relativeLabel) · Modified \(original.updatedAt.relativeLabel)")
                    }
                    .listRowBackground(Color.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle(original == nil ? String(localized: "New Reminder") : String(localized: "Reminder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(original == nil ? String(localized: "Add") : String(localized: "OK")) { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    }
                }
            }
            .onChange(of: draftKey) { _, _ in scheduleAutosave() }
            .sheet(isPresented: $showsDestinationPicker) {
                ReminderDestinationPicker(selection: destination) { picked in
                    withAnimation(.snappy) { destination = picked }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showsPlacePicker) {
                PlacePickerSheet(initial: place) { selection in
                    withAnimation(.snappy) { place = selection }
                }
            }
            .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let original { store.delete(original) }
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: fill)
        .task {
            if case let .project(id, heading?) = destination, store.headings(ofProject: id).allSatisfy({ $0.id != heading }) {
                await store.loadProject(id)
            }
        }
    }

    /// Everything the form edits, so an embedded editor knows when to save.
    private var draftKey: [String] {
        [title, notes, hasDate ? "\(due.timeIntervalSince1970)" : "-", repeatChoice.rawValue, list, "\(priority)",
         place.map { "\($0.place.id):\($0.trigger)" } ?? "-", "\(destination)", "\(someday)"]
    }

    private var destinationSymbol: String {
        switch destination {
        case .inbox: "tray"
        case .area: "square.stack.3d.up"
        case .project: "circle.dashed.inset.filled"
        }
    }

    private func scheduleAutosave() {
        guard isEmbedded, original != nil, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private var quickDates: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                quick(String(localized: "In 1 hour")) { Date().addingTimeInterval(3600) }
                quick(String(localized: "Tonight")) { Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date() }
                quick(String(localized: "Tomorrow 9 AM")) { ReminderNotifications.tomorrowMorning() }
                quick(String(localized: "Monday 9 AM")) { ReminderParser.parse("x lundi 9h").dueAt ?? Date() }
                quick(String(localized: "In 1 week")) { ReminderParser.parse("x dans 1 semaine").dueAt ?? Date() }
            }
        }
        .scrollIndicators(.hidden)
        // Edge to edge inside the card so chips scroll under its border instead of being cut mid-card.
        .contentMargins(.horizontal, Spacing.md, for: .scrollContent)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    private func quick(_ label: String, _ date: @escaping () -> Date) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.snappy) { due = date() }
        } label: {
            ChipButtonLabel(title: label)
        }
        .buttonStyle(.plain)
    }

    private func fill() {
        if let original {
            title = original.title
            notes = original.notes ?? ""
            hasDate = original.effectiveDate != nil
            due = original.effectiveDate ?? ReminderNotifications.tomorrowMorning()
            repeatChoice = RepeatChoice(rule: original.repeat)
            list = original.list
            priority = original.priority
            place = original.place.map { PlaceSelection(place: $0, trigger: original.placeTrigger ?? "arrive") }
            destination = ReminderFiling.destination(of: original)
            someday = original.isSomeday
            checklist = original.checklist ?? []
            if RemindersDemo.placePicker == original.id { showsPlacePicker = true }
        } else if let parsed = target.parsed {
            title = parsed.title
            hasDate = parsed.dueAt != nil
            due = parsed.dueAt ?? ReminderNotifications.tomorrowMorning()
            repeatChoice = RepeatChoice(rule: parsed.repeat)
            list = parsed.list ?? "inbox"
            priority = parsed.priority
            place = parsed.place.map { PlaceSelection(place: $0.asReminderPlace, trigger: parsed.placeTrigger ?? "arrive") }
            destination = parsed.destination ?? .inbox
            someday = parsed.someday
            titleFocused = parsed.title.isEmpty
        } else {
            due = ReminderNotifications.tomorrowMorning()
            titleFocused = true
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = repeatChoice.rule(due: hasDate ? due : nil, original: original?.repeat)
        let cleanChecklist = checklist.map { ChecklistItem(title: $0.title.trimmingCharacters(in: .whitespaces), done: $0.done) }.filter { !$0.title.isEmpty }
        guard let original else {
            var draft = ReminderDraft(title: cleanTitle, notes: cleanNotes.isEmpty ? nil : cleanNotes, dueAt: hasDate ? due : nil,
                                      repeat: rule, list: list, priority: priority,
                                      placeId: place?.place.id, placeTrigger: place?.trigger)
            ReminderFiling.apply(destination, to: &draft)
            if someday { draft.someday = true }
            if !cleanChecklist.isEmpty { draft.checklist = cleanChecklist }
            let created = await store.create(draft)
            if created != nil { dismiss() }
            return
        }
        // Embedded, earlier autosaves already reached the store: diff against that, not the reminder it opened with.
        let base = isEmbedded ? (store.reminder(id: original.id) ?? original) : original
        var patch: [String: JSONValue] = [:]
        if cleanTitle != base.title { patch["title"] = .string(cleanTitle) }
        if cleanNotes != (base.notes ?? "") { patch["notes"] = cleanNotes.isEmpty ? .null : .string(cleanNotes) }
        let originalDate = base.effectiveDate
        if !hasDate, originalDate != nil { patch["dueAt"] = .null }
        if hasDate, originalDate.map({ abs($0.timeIntervalSince(due)) >= 60 }) ?? true { patch["dueAt"] = .string(NuoJSON.formatDate(due)) }
        if rule != base.repeat { patch["repeat"] = rule.map(JSONValue.string) ?? .null }
        if list != base.list { patch["list"] = .string(list) }
        if priority != base.priority { patch["priority"] = .number(Double(priority)) }
        if place?.place.id != base.place?.id { patch["placeId"] = place.map { .string($0.place.id) } ?? .null }
        if let place, place.trigger != base.placeTrigger { patch["placeTrigger"] = .string(place.trigger) }
        if place == nil, base.placeTrigger != nil { patch["placeTrigger"] = .null }
        if destination != ReminderFiling.destination(of: base) { patch.merge(ReminderFiling.patch(destination)) { $1 } }
        if someday != base.isSomeday { patch["someday"] = .bool(someday) }
        if cleanChecklist != (store.reminder(id: original.id)?.checklist ?? []) { await store.setChecklist(original, cleanChecklist) }
        if isEmbedded && patch.isEmpty { return }
        if await store.update(original.id, patch: patch) {
            if !isEmbedded {
                Haptics.success()
                dismiss()
            }
        } else {
            Haptics.error()
        }
    }
}
