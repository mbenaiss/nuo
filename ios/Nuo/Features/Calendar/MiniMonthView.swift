import SwiftUI

/// Compact month: weekday letters, six weeks of days with event dots, today in accent, the selection inked.
struct MiniMonthView: View {
    @Binding var month: Date
    let selected: Date
    var showsHeader = true
    var showsTitle = true
    var cell: CGFloat = CalendarMetrics.miniMonthCell
    var dayFont: Font = .caption
    var dot: CGFloat = 4
    /// Days of the visible period (Mac week view) get a soft band.
    var highlighted: [Date] = []
    /// Long press (right click on Mac) offers a new event on that day.
    var onCreate: ((Date) -> Void)?
    let onSelect: (Date) -> Void

    @State private var store = CalendarStore.shared
    private var calendar: Calendar { AgendaCalendar.current }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            if showsHeader { header }
            let grid = AgendaCalendar.monthGrid(month)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(grid.prefix(7), id: \.self) { day in
                        Text(AgendaText.weekdayLetter(day))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.text3)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, Spacing.xxs)
                ForEach(0..<6, id: \.self) { week in
                    let days = Array(grid[(week * 7)..<(week * 7 + 7)])
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in dayCell(day) }
                    }
                    .background {
                        if days.contains(where: { day in highlighted.contains { calendar.isDate($0, inSameDayAs: day) } }) {
                            Capsule().fill(Color.chip)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            if showsTitle {
                Text(AgendaText.monthTitle(month)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            }
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.text2)
    }

    private func shift(_ months: Int) {
        withAnimation(.snappy) { month = calendar.date(byAdding: .month, value: months, to: month) ?? month }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let colors = store.dotColors(on: day)
        return Button {
            Haptics.selection()
            onSelect(day)
        } label: {
            VStack(spacing: 1) {
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(dayFont.weight(isToday || isSelected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.onInk : isToday ? Color.accent : inMonth ? Color.ink : Color.text3)
                    .frame(width: cell * 0.82, height: cell * 0.82)
                    .background(isSelected ? Color.inkFill : Color.clear, in: Circle())
                HStack(spacing: 2) {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                        Circle().fill(color.opacity(inMonth ? 1 : 0.4)).frame(width: dot, height: dot)
                    }
                }
                .frame(height: dot)
            }
            .frame(maxWidth: .infinity, minHeight: cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onCreate {
                Button("New event", systemImage: "plus") { onCreate(day) }
            }
        }
        .accessibilityLabel(AgendaText.dayTitle(day))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
