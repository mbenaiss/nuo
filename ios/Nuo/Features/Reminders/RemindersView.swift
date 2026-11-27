import SwiftUI

#if os(iOS)
/// Rappels tab: a Things-like home (smart lists, areas, projects) that opens on « Aujourd'hui ».
struct RemindersView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var workspace
    @State private var store = RemindersStore.shared
    @State private var nav = RemindersNavigator()

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.path) {
            RemindersHomeView()
                .navigationDestination(for: ReminderRoute.self) { route in
                    switch route {
                    case let .list(bucket): ReminderBucketView(bucket: bucket)
                    case let .project(id): ProjectScreen(projectId: id)
                    case let .area(id): AreaScreen(areaId: id)
                    }
                }
        }
        .sheet(item: $nav.editing) { target in
            ReminderDetailSheet(target: target, lists: store.lists)
        }
        .sheet(item: $nav.moving) { reminder in
            ReminderDestinationPicker(selection: ReminderFiling.destination(of: reminder)) { destination in
                Task { await store.move(reminder, to: destination) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $nav.projectEditor) { ProjectEditorSheet(target: $0) }
        .sheet(item: $nav.areaEditor) { AreaEditorSheet(target: $0) }
        .sheet(isPresented: $nav.showsPlaces) { PlacesView() }
        .modifier(OrganisationDialogs())
        .environment(nav)
        .task {
            store.attach(session.api)
            PlacesStore.shared.attach(session.api)
            async let places: Void = PlacesStore.shared.load()
            if !store.loaded { await store.load() }
            await places
            if let id = RemindersDemo.placePicker, let reminder = store.reminder(id: id) {
                nav.open(reminder)
            }
        }
        .onChange(of: workspace.focusedReminder) { _, id in openFocused(id) }
        .onAppear { openFocused(workspace.focusedReminder) }
    }

    /// `focusedReminder` is a reminder id, or `project/<id>` / `area/<id>` from `nuo://reminders/project/<id>`.
    private func openFocused(_ value: String?) {
        guard let value else { return }
        workspace.focusedReminder = nil
        let parts = value.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "project" || parts[0] == "area" {
            nav.editing = nil
            nav.path = [parts[0] == "project" ? .project(parts[1]) : .area(parts[1])]
            return
        }
        Task {
            if store.reminder(id: value) == nil { await store.load() }
            if let reminder = store.reminder(id: value) { nav.open(reminder) }
        }
    }
}
#endif

struct ReminderEditorTarget: Identifiable {
    let id = UUID()
    let reminder: Reminder?
    let parsed: ParsedReminder?
}

enum ReminderStyle {
    /// The gateway's default list is "inbox".
    static func listLabel(_ list: String) -> String {
        list.lowercased() == "inbox" ? String(localized: "Inbox") : list.prefix(1).uppercased() + list.dropFirst()
    }

    static func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 3: Color.bad
        case 2: Color(hex: 0xF59E0B)
        case 1: Color(hex: 0x3B82F6)
        default: Color.text3
        }
    }

    static func symbol(forList list: String) -> String {
        switch list.lowercased().folding(options: .diacriticInsensitive, locale: nil) {
        case "travail", "work", "pro": "briefcase"
        case "maison", "home": "house"
        case "sante", "health": "heart"
        case "voyages", "travel": "airplane"
        case "courses", "groceries": "cart"
        case "inbox": "tray"
        default: "tray"
        }
    }

    /// "9:00", "demain 9:00", "lun. 20 oct. 9:00", in red when overdue.
    static func dateLabel(_ date: Date, segment: ReminderSegment) -> String {
        let calendar = Calendar.current
        let time = ScheduleText.time(date)
        if segment == .today { return time }
        if segment == .upcoming { return time }
        if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)") }
        return "\(date.formatted(Date.FormatStyle(locale: ValueFormat.locale).weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }
}

struct ReminderRow: View {
    let reminder: Reminder
    let segment: ReminderSegment
    let completing: Bool
    /// Off inside a project or an area screen, where the caption would repeat the title.
    var showsParent = true
    let onToggle: () -> Void

    private var checked: Bool { reminder.isDone }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(checked ? Color.good : ReminderStyle.priorityColor(reminder.priority).opacity(reminder.priority > 0 ? 1 : 0.6), lineWidth: 1.8)
                    Circle()
                        .fill(Color.good)
                        .scaleEffect(checked ? 1 : 0.2)
                        .opacity(checked ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(checked ? 1 : 0.4)
                        .opacity(checked ? 1 : 0)
                }
                .frame(width: 24, height: 24)
                .animation(.spring(response: 0.32, dampingFraction: 0.6), value: checked)
                .contentShape(Circle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? String(localized: "Reopen") : String(localized: "Mark as done"))
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if reminder.priority > 0, !checked {
                        Text(String(repeating: "!", count: reminder.priority))
                            .font(.body.weight(.heavy))
                            .foregroundStyle(ReminderStyle.priorityColor(reminder.priority))
                    }
                    Text(reminder.title)
                        .font(.body)
                        .foregroundStyle(checked ? Color.text3 : Color.ink)
                        .strikethrough(checked && completing, color: Color.text3)
                        .lineLimit(2)
                }
                if hasMeta { meta }
            }
            Spacer(minLength: 0)
        }
        .opacity(completing ? 0.55 : 1)
        .animation(.easeOut(duration: 0.25), value: completing)
    }

    /// Things-like caption: the project, else the area, else a legacy list other than the inbox.
    private var parentLabel: String? {
        guard showsParent else { return nil }
        if let ref = reminder.project ?? reminder.area { return ReminderFiling.titled(ref.emoji, ref.title) }
        return reminder.list.lowercased() == "inbox" ? nil : ReminderStyle.listLabel(reminder.list)
    }

    private var hasMeta: Bool {
        reminder.effectiveDate != nil || (segment == .done && reminder.doneAt != nil) || reminder.repeat != nil || reminder.place != nil
            || parentLabel != nil || reminder.notes?.isEmpty == false || reminder.checklist?.isEmpty == false || reminder.isSomeday
    }

    @ViewBuilder
    private var meta: some View {
        let date = reminder.effectiveDate
        let overdue = !checked && (date.map { $0 < Date() } ?? false)
        let snoozed = reminder.snoozedUntil != nil && reminder.snoozedUntil == date
        HStack(spacing: 10) {
            if let date, segment != .done {
                Label {
                    Text(ReminderStyle.dateLabel(date, segment: overdue ? .overdue : segment))
                } icon: {
                    Image(systemName: snoozed ? "moon.zzz.fill" : "clock")
                }
                .foregroundStyle(overdue ? Color.bad : Color.text2)
            }
            if segment == .done, let done = reminder.doneAt {
                Label(ScheduleText.time(done), systemImage: "checkmark")
                    .foregroundStyle(Color.text3)
            }
            if reminder.isSomeday, !checked {
                Image(systemName: "archivebox").foregroundStyle(Color.text3).accessibilityLabel("Someday")
            }
            if let rule = reminder.repeat {
                Label(RepeatText.short(rule), systemImage: "repeat")
                    .foregroundStyle(Color.text2)
                    .lineLimit(1)
            }
            if let place = reminder.place {
                PlaceChip(name: place.name, trigger: reminder.placeTrigger)
            }
            if let checklist = reminder.checklist, !checklist.isEmpty {
                let progress = "\(checklist.filter(\.done).count)/\(checklist.count)"
                Label(progress, systemImage: "checklist")
                    .foregroundStyle(Color.text3)
                    .monospacedDigit()
            }
            if reminder.notes?.isEmpty == false {
                Image(systemName: "text.alignleft").foregroundStyle(Color.text3)
            }
            if let parentLabel {
                Text(parentLabel)
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        .font(.caption)
        .labelStyle(TightLabelStyle())
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption2.weight(.semibold))
            configuration.title
        }
    }
}

/// Bottom field: type « Appeler le garage demain 9h #lumen » and press return.
struct QuickAddBar: View {
    var defaultList: String?
    /// Where a reminder goes when the text names no `#projet` or `#domaine`.
    var destination: ReminderDestination?
    var someday = false
    /// Shown above the field while it files under a heading.
    var targetLabel: String?
    var onClearTarget: (() -> Void)?
    /// Bump to focus the field.
    var focusRequest = 0
    let onAdd: (ReminderDraft) async -> Bool
    let onDetails: (ParsedReminder) -> Void
    @State private var text = ""
    @State private var dictationKey = "reminder-\(UUID().uuidString)"
    @State private var sending = false
    @FocusState private var focused: Bool

    private var parsed: ParsedReminder {
        let store = RemindersStore.shared
        var result = ReminderParser.parse(text, places: PlacesStore.shared.places, projects: store.projects.filter(\.isOpen), areas: store.areas)
        if result.destination == nil { result.destination = destination }
        result.someday = someday
        return result
    }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let parsed = self.parsed
        VStack(alignment: .leading, spacing: 4) {
            if let targetLabel {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.caption2.weight(.bold))
                    Text(targetLabel).font(.footnote.weight(.semibold)).lineLimit(1)
                    if let onClearTarget {
                        Button(action: onClearTarget) {
                            Image(systemName: "xmark.circle.fill").font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove heading")
                    }
                }
                .foregroundStyle(Color.text2)
                .padding(.horizontal, Spacing.xs)
                .padding(.top, Spacing.xxs)
            }
            if !trimmed.isEmpty, parsed.hasExtras {
                ParsedPreview(parsed: parsed)
                    .padding(.top, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accent)
                    .padding(.leading, 6)
                TextField("New reminder… (in French) “demain 9h”", text: $text)
                    .font(.body)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .frame(minHeight: 44)
                if trimmed.isEmpty || DictationController.shared.isActive(dictationKey) {
                    DictationButton(key: dictationKey, text: $text, size: 36, compact: true)
                }
                if !trimmed.isEmpty {
                    Button {
                        Haptics.tap()
                        onDetails(parsed)
                        text = ""
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.text2)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Details")
                    RoundIconButton(symbol: sending ? "hourglass" : "arrow.up", size: 40, label: String(localized: "Add"), action: submit)
                        .disabled(sending)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassSurface(radius: 28)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: parsed.hasExtras && !trimmed.isEmpty)
        .animation(.snappy(duration: 0.2), value: trimmed.isEmpty)
        .task {
            if let draft = RemindersDemo.quickAddDraft { text = draft }
        }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty, !sending else { return }
        let result = parsed
        sending = true
        Task {
            if result.place != nil { await LocationAccess.shared.requestIfNeeded() }
            var draft = ReminderDraft(title: result.title, notes: nil, dueAt: result.dueAt, repeat: result.repeat,
                                      list: result.list ?? defaultList, priority: result.priority > 0 ? result.priority : nil,
                                      placeId: result.place?.id, placeTrigger: result.placeTrigger)
            if let destination = result.destination { ReminderFiling.apply(destination, to: &draft) }
            if result.someday { draft.someday = true }
            let ok = await onAdd(draft)
            sending = false
            if ok { text = "" }
        }
    }
}

struct ParsedPreview: View {
    let parsed: ParsedReminder

    var body: some View {
        WrapLayout(spacing: 6) {
                if let date = parsed.dueAt {
                    chip(ReminderDateText.full(date), symbol: "calendar", tint: Color.accentInk, fill: Color.accentSoft)
                }
                if let rule = parsed.repeat {
                    chip(RepeatText.describe(rule), symbol: "repeat", tint: Color(hex: 0x2563EB), fill: Color(hex: 0x3B82F6).opacity(0.14))
                }
                if let place = parsed.place {
                    PlaceChip(name: place.name, trigger: parsed.placeTrigger, compact: false)
                }
                if let label = parsed.destinationLabel {
                    chip(label, symbol: parsed.destination.map(Self.symbol) ?? "tray", tint: Color.ink, fill: Color.chip)
                }
                if let list = parsed.list {
                    chip(ReminderStyle.listLabel(list), symbol: ReminderStyle.symbol(forList: list), tint: Color.ink, fill: Color.chip)
                }
                if parsed.priority > 0 {
                    chip(["", String(localized: "Low"), String(localized: "Medium"), String(localized: "High")][parsed.priority], symbol: "flag.fill", tint: ReminderStyle.priorityColor(parsed.priority), fill: ReminderStyle.priorityColor(parsed.priority).opacity(0.14))
                }
        }
        .padding(.horizontal, 4)
    }

    private static func symbol(_ destination: ReminderDestination) -> String {
        switch destination {
        case .inbox: "tray"
        case .area: "square.stack.3d.up"
        case .project: "circle.dashed.inset.filled"
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color, fill: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fill, in: Capsule())
    }
}

enum ReminderDateText {
    /// "Aujourd'hui 18:00", "Demain 9:00", "Lundi 20 oct. 8:00".
    static func full(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = ScheduleText.time(date)
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow \(time)") }
        let day = date.formatted(Date.FormatStyle(locale: ValueFormat.locale).weekday(.wide).day().month(.abbreviated))
        return "\(day.prefix(1).uppercased())\(day.dropFirst()) \(time)"
    }
}

enum RemindersDemo {
    /// `-demoPlacePicker <reminderId>` opens that reminder and its place picker.
    static var placePicker: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoPlacePicker"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `-demoRemindersHome` lands on the Rappels home instead of « Aujourd'hui ».
    static var opensHome: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoRemindersHome")
    }

    /// `-demoReminderDraft "…"` pre-fills the quick-add field.
    static var quickAddDraft: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoReminderDraft"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
