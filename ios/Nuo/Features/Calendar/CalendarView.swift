import SwiftUI

#if os(iOS)

enum CalendarMode: String, CaseIterable, Identifiable {
    case list, day, threeDays, week, month
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: String(localized: "List")
        case .day: String(localized: "Day")
        case .threeDays: String(localized: "3 days")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .day: "calendar.day.timeline.left"
        case .threeDays: "rectangle.split.3x1"
        case .week: "square.grid.4x3.fill"
        case .month: "calendar"
        }
    }
}

/// The Calendar tab: day strip (pull it down for the month), agenda list or time grids, quick add at the bottom.
struct CalendarView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = CalendarStore.shared
    @State private var bridge = CalendarBridge.shared
    @State private var bookings = BookingStore.shared
    @State private var selectedDay = AgendaCalendar.current.startOfDay(for: Date())
    @State private var mode: CalendarMode = CalendarDemo.mode ?? CalendarMode(rawValue: UserDefaults.standard.string(forKey: "nuo.calendar.mode") ?? "") ?? .list
    @State private var monthExpanded = false
    @State private var detail: AgendaItem?
    @State private var editor: EventEditorTarget?
    @State private var path: [CalendarRoute] = []
    /// Bumped to make the list scroll to `selectedDay` (a tap, not a scroll).
    @State private var jump = 0
    @AppStorage("nuo.calendar.accessDismissed") private var accessDismissed = false

    enum CalendarRoute: Hashable { case bookings, settings }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if mode != .month {
                    CalendarHeader(selectedDay: $selectedDay, expanded: $monthExpanded, weekMode: mode == .week,
                                   showsStrip: mode == .list || mode == .day) { day in
                        selectedDay = day
                        jump += 1
                    }
                    Divider().overlay(Color.line)
                }
                content
            }
            .background(Color.canvas)
            .navigationTitle(AgendaText.monthTitle(selectedDay))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                EventQuickAddBar { parsed in
                    editor = EventEditorTarget(item: nil, draft: EventDraft(parsed, calendarId: bridge.defaultCalendarId))
                }
            }
            .navigationDestination(for: CalendarRoute.self) { route in
                switch route {
                case .bookings: BookingHomeView()
                case .settings: CalendarSettingsView()
                }
            }
            .sheet(item: $detail) { item in
                NavigationStack {
                    EventDetailView(uid: item.uid, seed: item) { detail = nil }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { detail = nil } } }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $editor) { target in EventEditorView(target: target) }
            .onChange(of: mode) { _, mode in UserDefaults.standard.set(mode.rawValue, forKey: "nuo.calendar.mode") }
        }
        .task {
            store.attach(session.api)
            bookings.attach(session.api)
            if !store.loaded { await store.load() }
            applyDemo()
            if bridge.access == .full { bridge.start() }
        }
        .onChange(of: workspace.focusedAgendaItem) { _, id in openFocused(id) }
        .onChange(of: workspace.showsBookings) { _, show in
            if show { workspace.showsBookings = false; path = [.bookings] }
        }
        .onAppear {
            openFocused(workspace.focusedAgendaItem)
            if workspace.showsBookings { workspace.showsBookings = false; path = [.bookings] }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.scheduleRefresh(after: .zero) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Today") {
                Haptics.selection()
                withAnimation(.snappy) { selectedDay = AgendaCalendar.current.startOfDay(for: Date()) }
                jump += 1
            }
            .font(.subheadline.weight(.semibold))
            .disabled(AgendaCalendar.current.isDateInToday(selectedDay) && mode != .list)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Display", selection: $mode) {
                    ForEach(CalendarMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Divider()
                Menu {
                    Toggle("Reminders", isOn: $store.showsReminders)
                    ForEach(store.calendars.filter(\.enabled)) { calendar in
                        Toggle(calendar.title, isOn: Binding(get: { !store.hiddenCalendars.contains(calendar.id) }, set: { _ in store.toggleVisibility(calendar.id) }))
                    }
                } label: { Label("Shown calendars", systemImage: "eye") }
                Button { path = [.settings] } label: { Label("Calendar settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: mode.symbol)
            }
            .accessibilityLabel("Display")
            Button { path = [.bookings] } label: { Image(systemName: "calendar.badge.clock") }
                .accessibilityLabel("Bookings")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .list:
            AgendaListView(selectedDay: $selectedDay, jump: jump, showsAccessCard: showsAccessCard, onDismissAccess: { accessDismissed = true }) { item in
                detail = item
            }
        case .day, .threeDays, .week:
            TimeGridView(days: gridDays, selectedUid: detail?.uid, showsHeader: mode != .day, onSelect: { detail = $0 }, onCreate: { start, end in
                editor = EventEditorTarget(item: nil, draft: EventDraft(title: "", start: start, end: end, calendarId: bridge.defaultCalendarId))
            }, onDayTap: mode == .day ? nil : { day in
                selectedDay = day
                mode = .day
            })
            .id(mode)
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 2, abs(value.translation.width) > 80 else { return }
                shiftPeriod(value.translation.width < 0 ? 1 : -1)
            })
        case .month:
            MonthAgendaView(selectedDay: $selectedDay, onSelect: { detail = $0 }, onCreate: { day in
                editor = EventEditorTarget(item: nil, draft: EventDraft.blank(on: day, calendarId: bridge.defaultCalendarId))
            })
        }
    }

    private var showsAccessCard: Bool {
        !bridge.isDemo && bridge.access != .full && !accessDismissed
    }

    private var gridDays: [Date] {
        switch mode {
        case .day: [selectedDay]
        case .threeDays: AgendaCalendar.days(from: selectedDay, count: 3)
        default: AgendaCalendar.days(from: AgendaCalendar.startOfWeek(selectedDay), count: 7)
        }
    }

    private func shiftPeriod(_ direction: Int) {
        Haptics.selection()
        let step = mode == .week ? 7 : mode == .threeDays ? 3 : 1
        withAnimation(.snappy) { selectedDay = AgendaCalendar.add(direction * step, to: selectedDay) }
    }

    private func openFocused(_ id: String?) {
        guard let id else { return }
        workspace.focusedAgendaItem = nil
        Task {
            if store.item(id: id) == nil { await store.load() }
            if let item = store.item(id: id) {
                selectedDay = AgendaCalendar.current.startOfDay(for: item.start)
                jump += 1
                detail = item
            }
        }
    }

    private func applyDemo() {
        if let title = CalendarDemo.eventTitle, let item = store.items.first(where: { $0.title == title }) {
            selectedDay = AgendaCalendar.current.startOfDay(for: item.start)
            detail = item
        }
        if CalendarDemo.opensBookings { path = [.bookings] }
        if CalendarDemo.opensSettings { path = [.settings] }
        if CalendarDemo.monthExpanded { monthExpanded = true }
    }
}

/// Week strip with busy dots; pulled down (or its handle tapped) it shows the whole month.
struct CalendarHeader: View {
    @Binding var selectedDay: Date
    @Binding var expanded: Bool
    var weekMode = false
    /// The time grids of several days carry their own day labels.
    var showsStrip = true
    let onPick: (Date) -> Void

    @State private var store = CalendarStore.shared
    @State private var month = Date()
    @State private var weekPosition: Date?
    @ScaledMetric(relativeTo: .callout) private var stripHeight = CalendarMetrics.tickerCellHeight

    private var calendar: Calendar { AgendaCalendar.current }

    private var weeks: [Date] {
        let first = AgendaCalendar.startOfWeek(store.range.start)
        let last = AgendaCalendar.startOfWeek(store.range.end)
        var result: [Date] = []
        var week = first
        while week <= last {
            result.append(week)
            week = AgendaCalendar.add(7, to: week)
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                MiniMonthView(month: $month, selected: selectedDay, highlighted: weekMode ? AgendaCalendar.days(from: AgendaCalendar.startOfWeek(selectedDay), count: 7) : []) { day in
                    onPick(day)
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.top, Spacing.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if showsStrip {
                strip
            }
            Capsule()
                .fill(Color.text3.opacity(0.5))
                .frame(width: Spacing.xxl + Spacing.xxs, height: Spacing.xxs)
                .padding(.vertical, Spacing.xs - 2)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityLabel(expanded ? String(localized: "Collapse month") : String(localized: "Show month"))
                .accessibilityAddTraits(.isButton)
        }
        .background(Color.canvas)
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            guard abs(value.translation.height) > abs(value.translation.width) else { return }
            if value.translation.height > 24, !expanded { toggle() }
            if value.translation.height < -24, expanded { toggle() }
        })
        .onAppear {
            month = selectedDay
            weekPosition = AgendaCalendar.startOfWeek(selectedDay)
        }
        .onChange(of: selectedDay) { _, day in
            let week = AgendaCalendar.startOfWeek(day)
            if weekPosition != week { withAnimation(.snappy) { weekPosition = week } }
            if !calendar.isDate(day, equalTo: month, toGranularity: .month) { month = day }
        }
    }

    private func toggle() {
        Haptics.selection()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(weeks, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(AgendaCalendar.days(from: week, count: 7), id: \.self) { day in dayCell(day) }
                    }
                    .padding(.horizontal, Spacing.xs)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $weekPosition)
        .scrollIndicators(.hidden)
        .frame(height: stripHeight)
        .padding(.top, Spacing.xxs)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let colors = store.dotColors(on: day)
        return Button {
            Haptics.selection()
            onPick(day)
        } label: {
            VStack(spacing: Spacing.xxs) {
                Text(AgendaText.weekdayLetter(day))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isToday ? Color.accent : Color.text3)
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.callout.weight(isSelected || isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.onInk : isToday ? Color.accent : Color.ink)
                    .frame(width: Spacing.xxl + Spacing.xxs, height: Spacing.xxl + Spacing.xxs)
                    .background(isSelected ? Color.inkFill : Color.clear, in: Circle())
                HStack(spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: CalendarMetrics.busyDot, height: CalendarMetrics.busyDot)
                    }
                }
                .frame(height: CalendarMetrics.busyDot)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AgendaText.dayTitle(day))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// « Mois »: the whole month (on top, or on the left when wide) and the picked day's items beside it.
struct MonthAgendaView: View {
    @Binding var selectedDay: Date
    let onSelect: (AgendaItem) -> Void
    let onCreate: (Date) -> Void

    @State private var store = CalendarStore.shared
    @ScaledMetric(relativeTo: .callout) private var cell = CalendarMetrics.monthGridCell

    /// Today when the month holds it, otherwise its first day.
    static func day(inMonthOf month: Date) -> Date {
        let calendar = AgendaCalendar.current
        if calendar.isDate(Date(), equalTo: month, toGranularity: .month) { return calendar.startOfDay(for: Date()) }
        return AgendaCalendar.startOfMonth(month)
    }

    private var month: Binding<Date> {
        Binding(get: { selectedDay }, set: { selectedDay = Self.day(inMonthOf: $0) })
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                HStack(spacing: 0) {
                    ScrollView { grid }
                        .scrollIndicators(.hidden)
                        .frame(width: min(proxy.size.width / 2, CalendarMetrics.monthGridMaxWidth))
                    Divider().overlay(Color.line)
                    dayList
                }
            } else {
                VStack(spacing: 0) {
                    grid
                    Divider().overlay(Color.line)
                    dayList
                }
            }
        }
        .task(id: "\(AgendaCalendar.startOfMonth(selectedDay).timeIntervalSince1970)-\(store.loaded)") {
            await store.ensureLoaded(AgendaCalendar.monthGridInterval(selectedDay))
        }
    }

    private var grid: some View {
        MiniMonthView(month: month, selected: selectedDay, showsTitle: false, cell: min(cell, CalendarMetrics.monthGridCell * 1.3), dayFont: .callout,
                      dot: CalendarMetrics.busyDot, onCreate: onCreate) { day in
            selectedDay = AgendaCalendar.current.startOfDay(for: day)
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 2, abs(value.translation.width) > 60 else { return }
            Haptics.selection()
            let next = AgendaCalendar.current.date(byAdding: .month, value: value.translation.width < 0 ? 1 : -1, to: selectedDay) ?? selectedDay
            withAnimation(.snappy) { selectedDay = Self.day(inMonthOf: next) }
        })
    }

    private var dayList: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if let error = store.error { StaleBanner(message: error) { Task { await store.load() } } }
                    if store.loaded {
                        AgendaDaySection(day: selectedDay, now: context.date, onSelect: onSelect)
                    } else {
                        SkeletonRows(count: 3)
                    }
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await store.load()
            await CalendarBridge.shared.sync()
        }
    }
}

/// Bottom field: « Dentiste jeudi 14h au 8 rue des Lilas » and return; chips show what was understood.
struct EventQuickAddBar: View {
    let onDetails: (ParsedEvent) -> Void
    @State private var store = CalendarStore.shared
    @State private var text = ""
    @State private var dictationKey = "event-\(UUID().uuidString)"
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var parsed: ParsedEvent { EventParser.parse(text, calendars: store.calendars) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func calendar(for parsed: ParsedEvent) -> CalendarInfo? {
        guard !parsed.needsGoogle else { return nil }
        return store.calendar(id: parsed.calendarId ?? CalendarBridge.shared.defaultCalendarId)
    }

    var body: some View {
        let parsed = self.parsed
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if !trimmed.isEmpty {
                ParsedEventPreview(parsed: parsed, calendar: calendar(for: parsed))
                    .padding(.top, Spacing.xs - 2)
                    .padding(.horizontal, Spacing.xxs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Color.bad).padding(.horizontal, Spacing.xs)
            }
            HStack(spacing: Spacing.sm - 2) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
                    .padding(.leading, Spacing.xs - 2)
                TextField("New event… (in French) “Déj jeudi 13h”", text: $text)
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
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xs - 2)
        .glassSurface(radius: Radius.xl)
        .padding(.horizontal, Spacing.gutter)
        .padding(.bottom, Spacing.xs)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: trimmed.isEmpty)
        .animation(.snappy(duration: 0.2), value: parsed)
        .task { if let draft = CalendarDemo.quickAddDraft { text = draft } }
    }

    private func submit() {
        guard !trimmed.isEmpty, !sending else { return }
        let result = parsed
        sending = true
        failure = nil
        Task {
            do {
                try await CalendarBridge.shared.create(EventDraft(result, calendarId: CalendarBridge.shared.defaultCalendarId))
                text = ""
            } catch {
                Haptics.error()
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
#endif

/// Days of the agenda as cards, « Maintenant » marker in today's, endless both ways (pages load near the edges).
struct AgendaListView: View {
    @Binding var selectedDay: Date
    let jump: Int
    var showsAccessCard = false
    var onDismissAccess: () -> Void = {}
    let onSelect: (AgendaItem) -> Void

    @State private var store = CalendarStore.shared
    @State private var position = ScrollPosition(idType: Date.self)
    @State private var programmatic = false
    /// First day rendered. Scrolling to a day makes the lazy stack size every section above it, so the past
    /// is revealed a page at a time when its top is reached instead of all at once.
    @State private var floor: Date?
    @State private var settled = false

    private static let pastDays = 7
    private static let pastPage = 21

    private static func floor(below day: Date) -> Date {
        AgendaCalendar.add(-pastDays, to: AgendaCalendar.current.startOfDay(for: day))
    }

    var body: some View {
        let all = store.agendaDays(including: [Date(), selectedDay])
        let start = floor ?? Self.floor(below: min(selectedDay, Date()))
        let firstShown = all.firstIndex { $0 >= start } ?? all.count
        let days = Array(all[firstShown...])
        let hasEarlier = firstShown > 0
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    if showsAccessCard {
                        CalendarAccessCard()
                            .overlay(alignment: .topTrailing) {
                                Button(action: onDismissAccess) {
                                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.text3).padding(Spacing.sm)
                                }
                                .accessibilityLabel("Hide")
                            }
                    }
                    if let error = store.error { StaleBanner(message: error) { Task { await store.load() } } }
                    if !store.loaded {
                        SkeletonRows(count: 5)
                    }
                    ForEach(days, id: \.self) { day in
                        AgendaDaySection(day: day, now: context.date, onSelect: onSelect)
                            .id(day)
                            .onAppear {
                                if day == days.first, hasEarlier {
                                    if settled, !programmatic { floor = AgendaCalendar.add(-Self.pastPage, to: start) }
                                } else if day == days.first || day == days.last {
                                    Task { await store.extend(toward: day) }
                                }
                            }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Spacing.gutter)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxl)
            }
            .scrollPosition($position, anchor: .topLeading)
            .scrollIndicators(.hidden)
            .refreshable {
                await store.load()
                await CalendarBridge.shared.sync()
            }
        }
        .onAppear {
            if floor == nil { floor = Self.floor(below: min(selectedDay, Date())) }
            scroll(to: selectedDay, animated: false)
        }
        // Lazy rows above the target only get their real height once laid out: aim again when the data lands.
        .onChange(of: store.loaded) { _, _ in scroll(to: selectedDay, animated: false) }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            scroll(to: selectedDay, animated: false)
            try? await Task.sleep(for: .milliseconds(500))
            settled = true
        }
        .onChange(of: jump) { _, _ in jumpTo(selectedDay) }
        .onChange(of: position.viewID(type: Date.self)) { _, day in
            guard let day, !programmatic else { return }
            if !AgendaCalendar.current.isDate(day, inSameDayAs: selectedDay) { selectedDay = day }
        }
    }

    /// A nearby day scrolls there; a far one becomes the top of the list (a week above it), so the jump never
    /// sizes the weeks in between.
    private func jumpTo(_ day: Date) {
        if let floor, day >= floor, day < AgendaCalendar.add(Self.pastDays + Self.pastPage, to: floor) {
            return scroll(to: day, animated: true)
        }
        floor = Self.floor(below: day)
        scroll(to: day, animated: false)
    }

    private func scroll(to day: Date, animated: Bool) {
        let target = AgendaCalendar.current.startOfDay(for: day)
        programmatic = true
        if animated {
            withAnimation(.snappy) { position.scrollTo(id: target, anchor: .topLeading) }
        } else {
            position.scrollTo(id: target, anchor: .topLeading)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            programmatic = false
        }
    }

}

/// One day of the agenda: its title, then a card of its items with the « Maintenant » marker today.
struct AgendaDaySection: View {
    let day: Date
    let now: Date
    let onSelect: (AgendaItem) -> Void

    @State private var store = CalendarStore.shared

    var body: some View {
        let isToday = AgendaCalendar.current.isDateInToday(day)
        let items = isToday && CalendarDemo.emptyToday ? [] : store.items(on: day)
        let nowIndex = isToday ? items.firstIndex { !$0.allDay && $0.start > now } ?? items.count : nil
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(AgendaText.dayTitle(day))
                    .font(.title3.bold())
                    .foregroundStyle(isToday ? Color.accent : Color.ink)
                if let subtitle = AgendaText.daySubtitle(day) {
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.text3)
                }
                Spacer()
            }
            .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                HStack(spacing: Spacing.sm) {
                    if isToday { MascotView(state: .sleep, size: MascotMetrics.inline) }
                    Text(isToday ? String(localized: "Nothing planned today.") : String(localized: "Nothing planned."))
                        .font(.subheadline).foregroundStyle(Color.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CardMetrics.padding)
                .padding(.vertical, isToday ? CardMetrics.compactPadding : CardMetrics.padding)
                .groupCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.uid) { index, item in
                        if index == nowIndex, index > 0 { NowMarker(now: now) }
                        Button { onSelect(item) } label: {
                            AgendaRow(item: item, now: now) { store.toggleReminder(item) }
                                .padding(.horizontal, CardMetrics.rowInset)
                                .padding(.vertical, Spacing.xs)
                        }
                        .buttonStyle(.plain)
                        if index < items.count - 1, index + 1 != nowIndex {
                            Divider().overlay(Color.line).padding(.leading, CardMetrics.rowInset + CalendarMetrics.timeLabelWidth + Spacing.sm)
                        }
                    }
                    if nowIndex == items.count, items.count > 0 { NowMarker(now: now) }
                }
                .padding(.vertical, Spacing.xxs)
                .groupCard()
            }
        }
    }
}

/// « Maintenant » line between today's past and coming items.
struct NowMarker: View {
    let now: Date

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(AgendaText.time(now))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.xs - 2)
                .padding(.vertical, 2)
                .background(Color.accent, in: Capsule())
            Rectangle().fill(Color.accent).frame(height: CalendarMetrics.nowLineWidth)
        }
        .padding(.horizontal, CardMetrics.rowInset)
        .padding(.vertical, Spacing.xxs)
        .accessibilityLabel("Now, \(AgendaText.time(now))")
    }
}

enum CalendarDemo {
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func argument(_ name: String) -> String? {
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func flag(_ name: String) -> Bool {
        arguments.contains("-demo") && arguments.contains(name)
    }

    #if os(iOS)
    /// `-demoCalendarMode list|day|threeDays|week|month`.
    static var mode: CalendarMode? { argument("-demoCalendarMode").flatMap(CalendarMode.init(rawValue:)) }
    #endif
    /// `-demoEvent "Déjeuner d'équipe"` opens that event's detail.
    static var eventTitle: String? { argument("-demoEvent") }
    /// `-demoEventDraft "…"` pre-fills the quick add field.
    static var quickAddDraft: String? { argument("-demoEventDraft") }
    /// `-demoBookings` opens « Rendez-vous » (with `-demoBooking editor|new|share|proposal` for a sheet).
    static var opensBookings: Bool { flag("-demoBookings") || argument("-demoBooking") != nil }
    static var opensSettings: Bool { flag("-demoCalendarSettings") }
    static var monthExpanded: Bool { flag("-demoMonth") }
    /// `-demoEmptyToday` shows today with nothing planned, for the empty-day state.
    static var emptyToday: Bool { flag("-demoEmptyToday") }
}
