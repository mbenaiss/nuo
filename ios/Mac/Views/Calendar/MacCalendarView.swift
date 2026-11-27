import SwiftUI

enum MacCalendarMode: String, CaseIterable, Identifiable {
    case day, week, month, list
    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: String(localized: "Day")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .list: String(localized: "List")
        }
    }

    /// ⌃1 … ⌃4 (⌘1 … ⌘6 already go to the sidebar sections).
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// Fantastical-like calendar: mini month, upcoming items and calendars on the left; quick entry on top; day, week,
/// month or list in the middle; the selected event in the inspector.
struct MacCalendarView: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var store = CalendarStore.shared
    @State private var bridge = CalendarBridge.shared
    @State private var month = Date()
    @State private var editor: EventEditorTarget?
    @State private var deleteError: String?

    private var calendar: Calendar { AgendaCalendar.current }

    private var visibleDays: [Date] {
        switch navigator.calendarMode {
        case .day: [navigator.calendarDate]
        case .week: AgendaCalendar.days(from: AgendaCalendar.startOfWeek(navigator.calendarDate), count: 7)
        case .month, .list: []
        }
    }

    var body: some View {
        @Bindable var navigator = navigator
        HStack(spacing: 0) {
            MacCalendarSidebar(month: $month)
                .frame(width: MacCalendarMetrics.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                header
                MacQuickEventField()
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
                Divider()
                main
            }
            .background(Color.canvas)
        }
        .background(Color.canvas)
        .inspector(isPresented: Binding(get: { navigator.calendarSelection != nil }, set: { if !$0 { navigator.calendarSelection = nil } })) {
            if let uid = navigator.calendarSelection, let item = store.item(uid: uid) {
                EventDetailView(uid: uid, seed: item) { navigator.calendarSelection = nil }
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                    .id(uid)
            } else {
                Color.canvas.inspectorColumnWidth(min: 320, ideal: 360, max: 480)
            }
        }
        .sheet(item: $editor) { target in EventEditorView(target: target) }
        .toolbar(removing: .title)
        .navigationTitle("Calendar")
        .toolbar { toolbar }
        .onKeyPress(.escape) {
            guard navigator.calendarSelection != nil else { return .ignored }
            navigator.calendarSelection = nil
            return .handled
        }
        .onDeleteCommand { deleteSelection() }
        .alert("Unable to delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task(id: navigator.refreshTick) {
            store.attach(session.api)
            await store.load()
        }
        .onAppear { month = navigator.calendarDate }
        .onChange(of: navigator.calendarDate) { _, date in
            if !calendar.isDate(date, equalTo: month, toGranularity: .month) { withAnimation(.snappy) { month = date } }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var navigator = navigator
        ToolbarItemGroup(placement: .navigation) {
            Button { navigator.shiftCalendar(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous period (⌘[)")
            Button("Today") { navigator.goToToday() }
                .help("Today (⌘T)")
            Button { navigator.shiftCalendar(1) } label: { Image(systemName: "chevron.right") }
                .help("Next period (⌘])")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $navigator.calendarMode) {
                ForEach(MacCalendarMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { navigator.sidebar = .booking } label: { Label("Bookings", systemImage: "calendar.badge.clock") }
                .help("Booking pages and reservations")
            Button {
                let start = EventParser.nextHalfHour(after: Date(), calendar: calendar)
                editor = EventEditorTarget(item: nil, draft: EventDraft(title: "", start: start, end: start.addingTimeInterval(3600), calendarId: bridge.defaultCalendarId))
            } label: { Label("New Event", systemImage: "plus") }
                .help("New event (⌘N for quick entry)")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(title).font(.largeTitle.bold()).foregroundStyle(Color.ink)
            if let subtitle { Text(subtitle).font(.title3).foregroundStyle(Color.text3) }
            Spacer()
            if bridge.isSyncing {
                ProgressView().controlSize(.small)
            } else if let error = bridge.lastError ?? store.error {
                Label("Sync failed", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.bad).help(error)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private var title: String {
        switch navigator.calendarMode {
        case .day: AgendaText.dayTitle(navigator.calendarDate)
        case .week, .month: AgendaText.monthTitle(navigator.calendarMode == .week ? AgendaCalendar.startOfWeek(navigator.calendarDate).addingTimeInterval(3 * 86400) : navigator.calendarDate)
        case .list: String(localized: "Agenda")
        }
    }

    private var subtitle: String? {
        switch navigator.calendarMode {
        case .day: AgendaText.daySubtitle(navigator.calendarDate) ?? AgendaText.monthTitle(navigator.calendarDate)
        case .week: String(localized: "Week \(calendar.component(.weekOfYear, from: navigator.calendarDate))")
        case .month, .list: nil
        }
    }

    @ViewBuilder
    private var main: some View {
        @Bindable var navigator = navigator
        if bridge.access != .full, !bridge.isDemo, store.calendars.isEmpty {
            CalendarAccessCard().frame(maxWidth: 520).padding(Spacing.xl)
            Spacer()
        } else {
            switch navigator.calendarMode {
            case .day, .week:
                TimeGridView(days: visibleDays, hourHeight: CalendarMetrics.compactHourHeight, selectedUid: navigator.calendarSelection,
                             allowsEditing: true, onSelect: { navigator.calendarSelection = $0.uid }, onCreate: create, onDayTap: { day in
                                 navigator.calendarDate = day
                                 navigator.calendarMode = .day
                             })
                    .id("\(navigator.calendarMode.rawValue)-\(visibleDays.first?.timeIntervalSince1970 ?? 0)")
                    .padding(.top, Spacing.xxs)
                    .task(id: "\(visibleDays.first?.timeIntervalSince1970 ?? 0)-\(visibleDays.count)-\(store.loaded)") {
                        guard let first = visibleDays.first, let last = visibleDays.last else { return }
                        await store.ensureLoaded(DateInterval(start: first, end: AgendaCalendar.add(1, to: last)))
                    }
            case .month:
                HStack(spacing: 0) {
                    MacMonthGrid(month: navigator.calendarDate, selectedDay: navigator.calendarDate, selectedUid: navigator.calendarSelection) { item in
                        navigator.calendarSelection = item.uid
                    } onSelectDay: { day in
                        navigator.calendarDate = day
                    } onOpenDay: { day in
                        navigator.calendarDate = day
                        navigator.calendarMode = .day
                    } onCreate: { day in
                        editor = EventEditorTarget(item: nil, draft: EventDraft.blank(on: day, calendarId: bridge.defaultCalendarId))
                    }
                    Divider()
                    monthDayList
                        .frame(width: MacCalendarMetrics.monthDayListWidth)
                }
                .task(id: "\(AgendaCalendar.startOfMonth(navigator.calendarDate).timeIntervalSince1970)-\(store.loaded)") {
                    await store.ensureLoaded(AgendaCalendar.monthGridInterval(navigator.calendarDate))
                }
            case .list:
                AgendaListView(selectedDay: $navigator.calendarDate, jump: navigator.calendarJump) { item in
                    navigator.calendarSelection = item.uid
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthDayList: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                AgendaDaySection(day: navigator.calendarDate, now: context.date) { item in
                    navigator.calendarSelection = item.uid
                }
            }
            .padding(Spacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.card.opacity(0.5))
    }

    private func create(_ start: Date, _ end: Date) {
        editor = EventEditorTarget(item: nil, draft: EventDraft(title: "", start: start, end: end, calendarId: bridge.defaultCalendarId))
    }

    private func deleteSelection() {
        guard let uid = navigator.calendarSelection, let item = store.item(uid: uid), bridge.canEdit(item), !item.isRecurring else { return }
        navigator.calendarSelection = nil
        Task {
            do {
                try await bridge.delete(item)
            } catch {
                Haptics.error()
                deleteError = error.localizedDescription
            }
        }
    }
}

enum MacCalendarMetrics {
    static let sidebarWidth: CGFloat = 268
    static let upcomingLimit = 6
    static let monthDayListWidth: CGFloat = 320
}

/// Left column: mini month, the next items with « Rejoindre », and which calendars are shown.
private struct MacCalendarSidebar: View {
    @Binding var month: Date
    @Environment(MacNavigator.self) private var navigator
    @State private var store = CalendarStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                MiniMonthView(month: $month, selected: navigator.calendarDate, highlighted: highlighted) { day in
                    navigator.calendarDate = day
                    navigator.calendarJump += 1
                }
                upcoming
                calendars
            }
            .padding(Spacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.card.opacity(0.5))
    }

    private var highlighted: [Date] {
        navigator.calendarMode == .week ? AgendaCalendar.days(from: AgendaCalendar.startOfWeek(navigator.calendarDate), count: 7) : []
    }

    private var upcoming: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let items = store.upcoming(limit: MacCalendarMetrics.upcomingLimit, from: context.date)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader(title: String(localized: "Upcoming"))
                if items.isEmpty {
                    HStack(spacing: Spacing.sm) {
                        MascotView(state: .sleep, size: MascotMetrics.inline)
                        Text("Nothing planned.").font(.callout).foregroundStyle(Color.text3)
                    }
                }
                ForEach(Array(items.enumerated()), id: \.element.uid) { index, item in
                    if index == 0 || !AgendaCalendar.current.isDate(item.start, inSameDayAs: items[index - 1].start) {
                        Text(AgendaText.dayTitle(item.start)).font(.caption.weight(.semibold)).foregroundStyle(Color.text2)
                            .padding(.top, index == 0 ? 0 : Spacing.xxs)
                    }
                    Button {
                        navigator.calendarDate = AgendaCalendar.current.startOfDay(for: item.start)
                        navigator.calendarSelection = item.uid
                    } label: {
                        upcomingRow(item, now: context.date)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func upcomingRow(_ item: AgendaItem, now: Date) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).font(.callout.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text(item.start <= now && item.kind != .reminder ? String(localized: "Now · until \(AgendaText.time(item.end))") : AgendaText.range(item))
                    .font(.caption.monospacedDigit()).foregroundStyle(item.start <= now ? Color.accent : Color.text2)
            }
            Spacer(minLength: 0)
            if let conference = item.conference {
                JoinButton(url: conference, prominent: item.start.timeIntervalSince(now) < 15 * 60)
            }
        }
        .padding(Spacing.xs)
        .background(navigator.calendarSelection == item.uid ? Color.chip : Color.clear, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .contentShape(Rectangle())
    }

    private var calendars: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader(title: String(localized: "Calendars"))
            ForEach(store.calendars.filter(\.enabled)) { info in
                Toggle(isOn: Binding(get: { !store.hiddenCalendars.contains(info.id) }, set: { _ in store.toggleVisibility(info.id) })) {
                    HStack(spacing: Spacing.xs) {
                        Text(info.title).lineLimit(1)
                        if info.isBusyOnly { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(Color.text3).help("Busy only") }
                    }
                }
                .toggleStyle(CalendarCheckboxStyle(color: Color(hexString: info.color ?? "") ?? Color.text2))
            }
            Toggle("Reminders", isOn: Binding(get: { store.showsReminders }, set: { store.showsReminders = $0 }))
                .toggleStyle(CalendarCheckboxStyle(color: Color.accent))
        }
    }
}

/// Colored checkbox like Calendar's sidebar.
private struct CalendarCheckboxStyle: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Spacing.xs) {
                RoundedRectangle(cornerRadius: Spacing.xxs, style: .continuous)
                    .fill(configuration.isOn ? color : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: Spacing.xxs, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                    .overlay { if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) } }
                    .frame(width: Spacing.md - 2, height: Spacing.md - 2)
                configuration.label.font(.callout).foregroundStyle(Color.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Top field: « Point Lumen Studio lundi 9h /pro » and return. ⌘N focuses it.
struct MacQuickEventField: View {
    @Environment(MacNavigator.self) private var navigator
    @State private var store = CalendarStore.shared
    @State private var text = ""
    @State private var dictationKey = "event-\(UUID().uuidString)"
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var parsed: ParsedEvent { EventParser.parse(text, calendars: store.calendars) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "calendar.badge.plus").foregroundStyle(Color.accent)
                TextField("New event… (in French) “Dentiste jeudi 14h au 8 rue des Lilas”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.escape) {
                        guard !text.isEmpty else { return .ignored }
                        text = ""
                        return .handled
                    }
                if sending { ProgressView().controlSize(.small) }
                DictationButton(key: dictationKey, text: $text, size: 26, compact: true)
                if !trimmed.isEmpty {
                    Text("↩︎ to add").font(.caption).foregroundStyle(Color.text3)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(focused ? Color.accent.opacity(0.6) : Color.line))
            if !trimmed.isEmpty {
                let parsed = self.parsed
                ParsedEventPreview(parsed: parsed, calendar: parsed.needsGoogle ? nil : store.calendar(id: parsed.calendarId ?? CalendarBridge.shared.defaultCalendarId))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(Color.bad) }
        }
        .animation(.snappy(duration: 0.2), value: trimmed.isEmpty)
        .onChange(of: navigator.calendarEntryFocus) { _, _ in focused = true }
        .onAppear {
            if let draft = CalendarDemo.quickAddDraft { text = draft }
            if navigator.calendarEntryFocus > 0 { focused = true }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !sending else { return }
        let result = parsed
        sending = true
        failure = nil
        Task {
            do {
                try await CalendarBridge.shared.create(EventDraft(result, calendarId: CalendarBridge.shared.defaultCalendarId))
                navigator.calendarDate = AgendaCalendar.current.startOfDay(for: result.start)
                text = ""
            } catch {
                Haptics.error()
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

extension MacNavigator {
    /// ⌘[ / ⌘]: a day, a week or a month back or forward.
    func shiftCalendar(_ direction: Int) {
        let calendar = AgendaCalendar.current
        switch calendarMode {
        case .day: calendarDate = AgendaCalendar.add(direction, to: calendarDate)
        case .week, .list: calendarDate = AgendaCalendar.add(7 * direction, to: calendarDate)
        case .month: calendarDate = calendar.date(byAdding: .month, value: direction, to: calendarDate) ?? calendarDate
        }
    }

    func goToToday() {
        calendarDate = AgendaCalendar.current.startOfDay(for: Date())
        calendarJump += 1
    }
}
