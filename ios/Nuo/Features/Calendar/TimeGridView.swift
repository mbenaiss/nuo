import SwiftUI

/// Columns of hours for one or more consecutive days: all-day strip, overlapping events side by side, « now » line,
/// busy-only events hatched. Long press (iPhone) or drag (Mac) on empty space creates an event; on the Mac,
/// events can be dragged to another time or day and resized from their bottom edge.
struct TimeGridView: View {
    let days: [Date]
    var hourHeight: CGFloat = CalendarMetrics.hourHeight
    var selectedUid: String?
    /// Drag to move or resize events (Mac).
    var allowsEditing = false
    var showsHeader = true
    var onSelect: (AgendaItem) -> Void = { _ in }
    var onCreate: (Date, Date) -> Void = { _, _ in }
    var onDayTap: ((Date) -> Void)?

    @State private var store = CalendarStore.shared
    @State private var creating: (day: Int, start: Double, end: Double)?
    @State private var scrolled = false
    @State private var failure: String?

    private var calendar: Calendar { AgendaCalendar.current }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, (proxy.size.width - CalendarMetrics.timeColumnWidth) / CGFloat(max(days.count, 1)))
            VStack(spacing: 0) {
                if showsHeader { header(columnWidth: columnWidth) }
                allDayStrip(columnWidth: columnWidth)
                Divider().overlay(Color.line)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                hourLabels
                                ZStack(alignment: .topLeading) {
                                    gridLines(columnWidth: columnWidth)
                                    creationLayer(columnWidth: columnWidth)
                                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                                        dayColumn(day, index: index, columnWidth: columnWidth)
                                    }
                                    nowLine(context.date, columnWidth: columnWidth)
                                    if let creating { ghost(creating, columnWidth: columnWidth) }
                                }
                                .frame(width: columnWidth * CGFloat(days.count), height: hourHeight * 24)
                            }
                            .padding(.bottom, Spacing.xl)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: .infinity)
                        .onAppear {
                            guard !scrolled else { return }
                            scrolled = true
                            // One day: from the current hour; several: from the start of a working day.
                            let today = days.count == 1 && calendar.isDateInToday(days[0])
                            let hour = today ? max(0, calendar.component(.hour, from: Date()) - 1) : CalendarMetrics.firstVisibleHour
                            reader.scrollTo("hour-\(min(hour, 16))", anchor: .top)
                            // The first layout pass may not have placed the rows yet (Mac windows): aim again.
                            Task {
                                try? await Task.sleep(for: .milliseconds(150))
                                reader.scrollTo("hour-\(min(hour, 16))", anchor: .top)
                            }
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .alert("Can't move event", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: Header

    private func header(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CalendarMetrics.timeColumnWidth, height: CalendarMetrics.dayHeaderHeight)
            ForEach(days, id: \.self) { day in
                let today = calendar.isDateInToday(day)
                Button {
                    onDayTap?(day)
                } label: {
                    VStack(spacing: 2) {
                        Text(AgendaText.weekdayShort(day).replacingOccurrences(of: ".", with: ""))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(today ? Color.accent : Color.text2)
                        Text(verbatim: "\(calendar.component(.day, from: day))")
                            .font(.callout.weight(today ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(today ? Color.white : Color.ink)
                            .frame(width: Spacing.xxl - Spacing.xxs, height: Spacing.xxl - Spacing.xxs)
                            .background(today ? Color.accent : Color.clear, in: Circle())
                    }
                    .frame(width: columnWidth, height: CalendarMetrics.dayHeaderHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onDayTap == nil)
            }
        }
    }

    // MARK: All-day strip

    private struct SpanPlacement: Identifiable {
        let item: AgendaItem
        let first: Int
        let last: Int
        let row: Int
        var id: String { item.uid }
    }

    private func allDayPlacements() -> (placements: [SpanPlacement], hidden: [Int: Int]) {
        guard let firstDay = days.first else { return ([], [:]) }
        let items = days.flatMap { store.items(on: $0) }.filter(\.allDay)
        var seen = Set<String>()
        var rowsEnd: [Int] = []
        var placements: [SpanPlacement] = []
        var hidden: [Int: Int] = [:]
        for item in items where seen.insert(item.uid).inserted {
            let indices = item.days.compactMap { day in days.firstIndex { calendar.isDate($0, inSameDayAs: day) } }
            guard let first = indices.min(), let last = indices.max() else { continue }
            if let row = rowsEnd.firstIndex(where: { $0 < first }) {
                rowsEnd[row] = last
                placements.append(SpanPlacement(item: item, first: first, last: last, row: row))
            } else {
                rowsEnd.append(last)
                placements.append(SpanPlacement(item: item, first: first, last: last, row: rowsEnd.count - 1))
            }
        }
        _ = firstDay
        for placement in placements where placement.row >= CalendarMetrics.allDayMaxRows {
            for day in placement.first...placement.last { hidden[day, default: 0] += 1 }
        }
        return (placements.filter { $0.row < CalendarMetrics.allDayMaxRows }, hidden)
    }

    @ViewBuilder
    private func allDayStrip(columnWidth: CGFloat) -> some View {
        let (placements, hidden) = allDayPlacements()
        if !placements.isEmpty {
            let rows = (placements.map(\.row).max() ?? 0) + 1 + (hidden.isEmpty ? 0 : 1)
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(Color.text3)
                    .frame(width: CalendarMetrics.timeColumnWidth - Spacing.xxs, alignment: .trailing)
                    .padding(.trailing, Spacing.xxs)
                    .padding(.top, Spacing.xxs + 1)
                ZStack(alignment: .topLeading) {
                    ForEach(placements) { placement in
                        Button { onSelect(placement.item) } label: {
                            allDayChip(placement.item)
                        }
                        .buttonStyle(.plain)
                        .frame(width: columnWidth * CGFloat(placement.last - placement.first + 1) - CalendarMetrics.eventGap * 2,
                               height: CalendarMetrics.allDayRowHeight - CalendarMetrics.eventGap)
                        .offset(x: columnWidth * CGFloat(placement.first) + CalendarMetrics.eventGap,
                                y: CGFloat(placement.row) * CalendarMetrics.allDayRowHeight)
                    }
                    ForEach(hidden.sorted(by: { $0.key < $1.key }), id: \.key) { day, count in
                        Text(verbatim: "+\(count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.text2)
                            .offset(x: columnWidth * CGFloat(day) + Spacing.xs, y: CGFloat(CalendarMetrics.allDayMaxRows) * CalendarMetrics.allDayRowHeight)
                    }
                }
                .frame(width: columnWidth * CGFloat(days.count), height: CGFloat(rows) * CalendarMetrics.allDayRowHeight, alignment: .topLeading)
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private func allDayChip(_ item: AgendaItem) -> some View {
        HStack(spacing: Spacing.xxs) {
            if item.isBooking { Text(verbatim: "📅").font(.caption2) }
            Text(item.displayTitle).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(item.isBusyOnly ? Color.text2 : Color.ink)
        .padding(.horizontal, Spacing.xs - 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { EventFill(item: item) }
        .clipShape(RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.tint).frame(width: 3).padding(.vertical, 3).padding(.leading, 2)
        }
        .overlay {
            if item.uid == selectedUid {
                RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius, style: .continuous).strokeBorder(item.tint, lineWidth: 2)
            }
        }
    }

    // MARK: Grid

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : "\(hour):00")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.text3)
                    .frame(width: CalendarMetrics.timeColumnWidth - Spacing.xs, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, Spacing.xs)
                    .offset(y: -Spacing.xs + 1)
                    .id("hour-\(hour)")
            }
        }
    }

    private func gridLines(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                Rectangle().fill(Color.line).frame(height: 1).offset(y: CGFloat(hour) * hourHeight)
            }
            ForEach(1..<max(days.count, 1), id: \.self) { index in
                Rectangle().fill(Color.line).frame(width: 1).offset(x: CGFloat(index) * columnWidth)
            }
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                if calendar.isDateInWeekend(day), days.count > 1 {
                    Rectangle().fill(Color.chip.opacity(0.45))
                        .frame(width: columnWidth, height: hourHeight * 24)
                        .offset(x: CGFloat(index) * columnWidth)
                }
            }
        }
        .frame(width: columnWidth * CGFloat(days.count), height: hourHeight * 24, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private struct Placement: Identifiable {
        let item: AgendaItem
        let top: CGFloat
        let height: CGFloat
        let column: Int
        let columns: Int
        var id: String { item.uid }
    }

    /// Clusters of overlapping events share the column width; each event takes the first free sub-column.
    private func placements(for day: Date) -> [Placement] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let timed = store.items(on: day).filter { !$0.allDay && $0.kind != .reminder }
        struct Span { let item: AgendaItem; let top: Double; let bottom: Double }
        let minSpan: TimeInterval = 15 * 60
        let snap = Double(CalendarMetrics.snapMinutes)
        var unsorted: [Span] = []
        for item in timed {
            let from: Date = max(item.start, start)
            let paddedEnd: Date = max(item.end, item.start.addingTimeInterval(minSpan))
            let to: Date = min(paddedEnd, end)
            let top: Double = WallClock.minutes(of: from, on: start, calendar: calendar)
            let toMinutes: Double = WallClock.minutes(of: to, on: start, calendar: calendar)
            let bottom: Double = max(top + snap, toMinutes)
            unsorted.append(Span(item: item, top: top, bottom: bottom))
        }
        let spans: [Span] = unsorted.sorted { $0.top != $1.top ? $0.top < $1.top : $0.bottom > $1.bottom }

        var result: [Placement] = []
        var cluster: [(Span, Int)] = []
        var columnsEnd: [Double] = []
        var clusterEnd = -1.0
        func flush() {
            let count = max(columnsEnd.count, 1)
            for (span, column) in cluster {
                result.append(Placement(item: span.item, top: CGFloat(span.top / 60) * hourHeight,
                                        height: max(CalendarMetrics.minEventHeight, CGFloat((span.bottom - span.top) / 60) * hourHeight),
                                        column: column, columns: count))
            }
            cluster = []
            columnsEnd = []
        }
        for span in spans {
            if span.top >= clusterEnd, !cluster.isEmpty { flush() }
            if let free = columnsEnd.firstIndex(where: { $0 <= span.top }) {
                columnsEnd[free] = span.bottom
                cluster.append((span, free))
            } else {
                columnsEnd.append(span.bottom)
                cluster.append((span, columnsEnd.count - 1))
            }
            clusterEnd = max(clusterEnd, span.bottom)
        }
        flush()
        return result
    }

    private func dayColumn(_ day: Date, index: Int, columnWidth: CGFloat) -> some View {
        let start = calendar.startOfDay(for: day)
        return ZStack(alignment: .topLeading) {
            ForEach(placements(for: day)) { placement in
                let width = (columnWidth - CalendarMetrics.eventGap * 2) / CGFloat(placement.columns)
                GridEventBlock(item: placement.item, selected: placement.item.uid == selectedUid, hourHeight: hourHeight,
                               dayWidth: columnWidth, narrow: width < CalendarMetrics.narrowEventWidth, editable: allowsEditing && CalendarBridge.shared.canEdit(placement.item),
                               onSelect: onSelect, onFailure: { failure = $0 })
                    .frame(width: max(width - CalendarMetrics.eventGap, 1), height: placement.height - CalendarMetrics.eventGap)
                    .offset(x: CGFloat(index) * columnWidth + CalendarMetrics.eventGap + CGFloat(placement.column) * width,
                            y: placement.top + CalendarMetrics.eventGap / 2)
            }
            // Reminders are moments, not spans: a thin pill over the events instead of a column of their own.
            ForEach(store.items(on: day).filter { $0.kind == .reminder }, id: \.uid) { item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 2) {
                        Image(systemName: item.done == true ? "checkmark.circle.fill" : "circle").font(.caption2.weight(.bold))
                            .foregroundStyle(item.tint)
                        if columnWidth > CalendarMetrics.timeColumnWidth * 1.5 {
                            Text(item.displayTitle).font(.caption2.weight(.medium)).lineLimit(1)
                                .strikethrough(item.done == true)
                        }
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, Spacing.xxs)
                    .frame(height: CalendarMetrics.minEventHeight - Spacing.xxs, alignment: .leading)
                    .background(Color.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.line))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: columnWidth * CalendarMetrics.reminderPillShare, alignment: .trailing)
                .frame(width: columnWidth - CalendarMetrics.eventGap * 2, alignment: .trailing)
                .offset(x: CGFloat(index) * columnWidth + CalendarMetrics.eventGap,
                        y: CGFloat(WallClock.minutes(of: item.start, on: start, calendar: calendar) / 60) * hourHeight - (CalendarMetrics.minEventHeight - Spacing.xxs) / 2)
            }
        }
    }

    @ViewBuilder
    private func nowLine(_ now: Date, columnWidth: CGFloat) -> some View {
        if let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) {
            let y = CGFloat(AgendaCalendar.minutes(now) / 60) * hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.accent).frame(width: columnWidth, height: CalendarMetrics.nowLineWidth)
                Circle().fill(Color.accent).frame(width: CalendarMetrics.nowDot, height: CalendarMetrics.nowDot)
                    .offset(x: -CalendarMetrics.nowDot / 2)
            }
            .offset(x: CGFloat(index) * columnWidth, y: y - CalendarMetrics.nowLineWidth / 2)
            .allowsHitTesting(false)
        }
    }

    // MARK: Creation

    private func snappedMinutes(_ y: CGFloat) -> Double {
        let raw = Double(y / hourHeight) * 60
        let step = Double(CalendarMetrics.snapMinutes)
        return min(24 * 60, max(0, (raw / step).rounded(.down) * step))
    }

    private func creationLayer(columnWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: columnWidth * CGFloat(days.count), height: hourHeight * 24)
            .contentShape(Rectangle())
            .gesture(creationGesture(columnWidth: columnWidth))
            #if os(macOS)
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                let index = min(days.count - 1, max(0, Int(value.location.x / columnWidth)))
                let start = snappedMinutes(value.location.y)
                commit(day: index, start: start, end: start + Double(CalendarMetrics.defaultDurationMinutes))
            })
            #endif
    }

    private func creationGesture(columnWidth: CGFloat) -> some Gesture {
        #if os(iOS)
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case let .second(true, drag?) = value else { return }
                update(drag, columnWidth: columnWidth)
            }
            .onEnded { value in
                guard case let .second(true, drag) = value else { creating = nil; return }
                if let drag { update(drag, columnWidth: columnWidth) }
                finishCreation()
            }
        #else
        DragGesture(minimumDistance: 4)
            .onChanged { update($0, columnWidth: columnWidth) }
            .onEnded { value in
                update(value, columnWidth: columnWidth)
                finishCreation()
            }
        #endif
    }

    private func update(_ drag: DragGesture.Value, columnWidth: CGFloat) {
        let index = min(days.count - 1, max(0, Int(drag.startLocation.x / columnWidth)))
        let a = snappedMinutes(drag.startLocation.y)
        let b = snappedMinutes(drag.location.y) + Double(CalendarMetrics.snapMinutes)
        if creating == nil { Haptics.selection() }
        creating = (index, min(a, b), max(max(a, b), min(a, b) + Double(CalendarMetrics.snapMinutes) * 2))
    }

    private func finishCreation() {
        guard let creating else { return }
        self.creating = nil
        commit(day: creating.day, start: creating.start, end: creating.end)
    }

    private func commit(day index: Int, start: Double, end: Double) {
        guard days.indices.contains(index) else { return }
        let day = calendar.startOfDay(for: days[index])
        onCreate(WallClock.date(on: day, minutes: start, calendar: calendar), WallClock.date(on: day, minutes: end, calendar: calendar))
    }

    private func ghost(_ creating: (day: Int, start: Double, end: Double), columnWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius, style: .continuous)
            .fill(Color.accent.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius, style: .continuous).strokeBorder(Color.accent, lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                Text(verbatim: "\(ScheduleText.time(hour: Int(creating.start) / 60, minute: Int(creating.start) % 60)) – \(ScheduleText.time(hour: Int(creating.end) / 60 % 24, minute: Int(creating.end) % 60))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.accentInk)
                    .padding(Spacing.xxs)
            }
            .frame(width: columnWidth - CalendarMetrics.eventGap * 2, height: CGFloat((creating.end - creating.start) / 60) * hourHeight)
            .offset(x: CGFloat(creating.day) * columnWidth + CalendarMetrics.eventGap, y: CGFloat(creating.start / 60) * hourHeight)
            .allowsHitTesting(false)
    }
}

/// An event in a time grid. Editable blocks follow a drag (move, possibly to another day) and a drag on their
/// bottom edge (resize), snapped to 15 minutes, then write through EventKit.
private struct GridEventBlock: View {
    let item: AgendaItem
    let selected: Bool
    let hourHeight: CGFloat
    let dayWidth: CGFloat
    /// A week on a phone: tiny text that wraps, no times.
    var narrow = false
    let editable: Bool
    let onSelect: (AgendaItem) -> Void
    var onFailure: (String) -> Void = { _ in }

    @State private var moveOffset: CGSize = .zero
    @State private var resizeOffset: CGFloat = 0
    @State private var dragging = false

    private var snapHeight: CGFloat { hourHeight * CGFloat(CalendarMetrics.snapMinutes) / 60 }

    var body: some View {
        let isReminder = item.kind == .reminder
        content(isReminder: isReminder)
            .padding(.bottom, -resizeOffset)
            .offset(snapped(moveOffset))
            .shadow(color: dragging ? .black.opacity(0.18) : .clear, radius: 8, y: 4)
            .zIndex(dragging ? 1 : 0)
            .onTapGesture { onSelect(item) }
            .gesture(moveGesture, including: editable ? .all : .subviews)
            .overlay(alignment: .bottom) {
                if editable {
                    Color.clear
                        .frame(height: Spacing.xs)
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        #endif
                        .gesture(resizeGesture)
                        .offset(y: resizeOffset)
                }
            }
            .help(item.displayTitle)
    }

    @ViewBuilder
    private func content(isReminder: Bool) -> some View {
        let compact = hourHeight * item.duration / 3600 < CalendarMetrics.minEventHeight * 2
        if narrow {
            Text(item.displayTitle)
                .font(.system(size: CalendarMetrics.narrowEventFont, weight: .semibold))
                .foregroundStyle(item.isBusyOnly ? Color.text2 : Color.ink)
                .lineLimit(nil)
                .padding(.leading, Spacing.xxs + 1)
                .padding(.trailing, 1)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { EventFill(item: item) }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(item.tint).frame(width: 2).padding(.vertical, 1)
                }
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius - 2, style: .continuous).strokeBorder(item.tint, lineWidth: 1.5) }
                }
                .clipShape(RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius - 2, style: .continuous))
        } else {
            wideContent(isReminder: isReminder, compact: compact)
        }
    }

    @ViewBuilder
    private func wideContent(isReminder: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Spacing.xxs) {
                if isReminder {
                    Image(systemName: item.done == true ? "checkmark.circle.fill" : "circle").font(.caption2.weight(.bold))
                } else if item.isBooking {
                    Text(verbatim: "📅").font(.caption2)
                }
                Text(item.displayTitle)
                    .font(.caption.weight(.semibold))
                    .strikethrough(item.isCancelled || item.done == true)
                    .lineLimit(compact ? 1 : 2)
                if compact, !isReminder {
                    Text(AgendaText.time(item.start)).font(.caption2.monospacedDigit()).foregroundStyle(Color.text2)
                }
            }
            if !compact {
                Text(AgendaText.range(item)).font(.caption2.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                if let location = item.location, !location.isEmpty {
                    Text(location).font(.caption2).foregroundStyle(Color.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(item.isBusyOnly ? Color.text2 : Color.ink)
        .padding(.leading, Spacing.xs - 1)
        .padding(.trailing, Spacing.xxs)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if isReminder { Color.card } else { EventFill(item: item) }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.tint).frame(width: 3).padding(.vertical, 2).padding(.leading, 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius, style: .continuous)
                .strokeBorder(selected ? item.tint : (isReminder ? Color.line : Color.clear), lineWidth: selected ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: CalendarMetrics.eventRadius, style: .continuous))
    }

    private func snapped(_ size: CGSize) -> CGSize {
        let days = (size.width / dayWidth).rounded()
        return CGSize(width: days * dayWidth, height: (size.height / snapHeight).rounded() * snapHeight)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if !dragging { dragging = true; Haptics.selection() }
                moveOffset = value.translation
            }
            .onEnded { value in
                let offset = snapped(value.translation)
                dragging = false
                moveOffset = .zero
                let days = Int(offset.width / dayWidth)
                let minutes = Double(offset.height / snapHeight) * Double(CalendarMetrics.snapMinutes)
                guard days != 0 || minutes != 0 else { return }
                let calendar = AgendaCalendar.current
                commit(start: WallClock.shift(item.start, days: days, minutes: minutes, calendar: calendar),
                       end: WallClock.shift(item.end, days: days, minutes: minutes, calendar: calendar))
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragging = true
                let minimum = snapHeight * 2 - hourHeight * item.duration / 3600
                resizeOffset = max(minimum, (value.translation.height / snapHeight).rounded() * snapHeight)
            }
            .onEnded { _ in
                dragging = false
                let minutes = Double(resizeOffset / snapHeight) * Double(CalendarMetrics.snapMinutes)
                resizeOffset = 0
                guard minutes != 0 else { return }
                commit(start: item.start, end: item.end.addingTimeInterval(minutes * 60))
            }
    }

    private func commit(start: Date, end: Date) {
        Task {
            do {
                try await CalendarBridge.shared.move(item, start: start, end: end)
            } catch {
                Haptics.error()
                onFailure(error.localizedDescription)
                CalendarStore.shared.scheduleRefresh(after: .zero)
            }
        }
    }
}
