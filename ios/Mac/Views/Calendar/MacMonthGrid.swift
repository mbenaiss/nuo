import SwiftUI

/// Six weeks of the month: each day lists its first items (time and title, colored), « + n » for the rest.
/// Click a day to list it beside the grid, an item to inspect it, double-click a day to open it.
struct MacMonthGrid: View {
    let month: Date
    let selectedDay: Date
    let selectedUid: String?
    let onSelect: (AgendaItem) -> Void
    let onSelectDay: (Date) -> Void
    let onOpenDay: (Date) -> Void
    let onCreate: (Date) -> Void

    @State private var store = CalendarStore.shared
    private var calendar: Calendar { AgendaCalendar.current }

    var body: some View {
        let days = AgendaCalendar.monthGrid(month)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { day in
                    Text(AgendaText.weekdayShort(day).replacingOccurrences(of: ".", with: ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, Spacing.xs)
                }
            }
            .padding(.vertical, Spacing.xs)
            Divider().overlay(Color.line)
            GeometryReader { proxy in
                let rowHeight = proxy.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                                cell(day, height: rowHeight)
                                if calendar.component(.weekday, from: day) != 1 { Divider().overlay(Color.line) }
                            }
                        }
                        .frame(height: rowHeight)
                        Divider().overlay(Color.line)
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, height: CGFloat) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let items = store.items(on: day)
        let capacity = max(1, Int((height - CalendarMetrics.dayHeaderHeight * 0.6) / (CalendarMetrics.allDayRowHeight - Spacing.xxs)) - 1)
        let shown = Array(items.prefix(min(capacity, CalendarMetrics.monthMaxChips)))
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : isSelected ? Color.onInk : inMonth ? Color.ink : Color.text3)
                    .frame(minWidth: Spacing.xl, minHeight: Spacing.xl)
                    .background(isToday ? Color.accent : isSelected ? Color.inkFill : Color.clear, in: Circle())
            }
            ForEach(shown, id: \.uid) { item in
                Button {
                    onSelectDay(day)
                    onSelect(item)
                } label: { chip(item) }
                    .buttonStyle(.plain)
            }
            if items.count > shown.count {
                Text(items.count - shown.count == 1 ? String(localized: "+ 1 more") : String(localized: "+ \(items.count - shown.count) more"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.text2)
                    .padding(.leading, Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.xxs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(calendar.isDateInWeekend(day) ? Color.chip.opacity(0.4) : Color.clear)
        .opacity(inMonth ? 1 : 0.6)
        .overlay {
            if isSelected { Rectangle().strokeBorder(Color.accent.opacity(0.5), lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenDay(day) }
        .onTapGesture { onSelectDay(day) }
        .contextMenu {
            Button("New Event", systemImage: "plus") { onCreate(day) }
        }
    }

    private func chip(_ item: AgendaItem) -> some View {
        HStack(spacing: Spacing.xxs) {
            if item.allDay || item.isBusyOnly {
                Text(item.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Circle().fill(item.tint).frame(width: CalendarMetrics.busyDot + 1, height: CalendarMetrics.busyDot + 1)
                Text(AgendaText.time(item.start)).font(.caption2.monospacedDigit()).foregroundStyle(Color.text2)
                Text(item.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
                    .strikethrough(item.done == true || item.isCancelled)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(item.isBusyOnly ? Color.text2 : Color.ink)
        .padding(.horizontal, Spacing.xxs + 1)
        .frame(height: CalendarMetrics.allDayRowHeight - Spacing.xxs)
        .background {
            if item.allDay || item.isBusyOnly { EventFill(item: item) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Spacing.xxs + 1, style: .continuous))
        .overlay {
            if item.uid == selectedUid {
                RoundedRectangle(cornerRadius: Spacing.xxs + 1, style: .continuous).strokeBorder(item.tint, lineWidth: 1.5)
            }
        }
        .help(item.displayTitle)
    }
}
