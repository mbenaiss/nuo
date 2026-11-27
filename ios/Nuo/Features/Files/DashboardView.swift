import Charts
import SwiftUI

enum ChartPalette {
    static let colors: [Color] = [
        Color.accent, Color(hex: 0x3B82F6), Color(hex: 0x1F9D57), Color(hex: 0xA855F7),
        Color(hex: 0xF59E0B), Color(hex: 0xEC4899), Color(hex: 0x14B8A6), Color(hex: 0x8B8A91),
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

struct DashboardView: View {
    let slug: String
    @Environment(SessionStore.self) private var session
    @State private var store: DashboardStore

    init(slug: String) {
        self.slug = slug
        _store = State(initialValue: DashboardStore(slug: slug))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DashboardMetrics.sectionGap) {
                if let dashboard = store.dashboard {
                    header(dashboard)
                    if let error = store.error {
                        StaleBanner(message: error) { Task { await store.load() } }
                    }
                    blocks(dashboard.blocks)
                } else if let error = store.error {
                    WorkspaceEmptyState(symbol: "chart.bar.xaxis", title: String(localized: "Dashboard unavailable"), message: error)
                } else {
                    skeleton
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle(store.dashboard.map { "\($0.emoji.map { "\($0) " } ?? "")\($0.title)" } ?? "")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await store.load() }
        .task {
            store.attach(session.api)
            await store.load()
        }
    }

    @ViewBuilder
    private func header(_ dashboard: Dashboard) -> some View {
        if dashboard.description != nil || store.loading {
            HStack(spacing: Spacing.xs) {
                if let description = dashboard.description {
                    Text(description).font(.subheadline).foregroundStyle(Color.text2)
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }
        }
    }

    /// Consecutive number blocks share a grid of tiles (the dashboard's first one is a full-width hero);
    /// charts and tables take one column on iPhone.
    @ViewBuilder
    private func blocks(_ blocks: [DashboardBlock]) -> some View {
        let groups = Self.group(blocks)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            let isNumbers = group.first?.type == .number && group.first?.error == nil
            if isNumbers {
                if index == 0, let first = group.first {
                    DashboardBlockView(block: first, hero: true)
                }
                let rest = index == 0 ? Array(group.dropFirst()) : group
                if !rest.isEmpty {
                    DashboardGrid(minColumnWidth: DashboardMetrics.tileMinWidth, maxColumns: 2) {
                        ForEach(Array(rest.enumerated()), id: \.offset) { _, block in
                            DashboardBlockView(block: block)
                        }
                    }
                }
            } else {
                ForEach(Array(group.enumerated()), id: \.offset) { _, block in
                    DashboardBlockView(block: block)
                }
            }
        }
    }

    private static func group(_ blocks: [DashboardBlock]) -> [[DashboardBlock]] {
        var groups: [[DashboardBlock]] = []
        for block in blocks {
            if block.type == .number, block.error == nil, let last = groups.last, last.allSatisfy({ $0.type == .number && $0.error == nil }) {
                groups[groups.count - 1].append(block)
            } else {
                groups.append([block])
            }
        }
        return groups
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: DashboardMetrics.sectionGap) {
            HStack(spacing: Spacing.sm) {
                SkeletonBar(width: 46, height: 46)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SkeletonBar(width: 160, height: 18)
                    SkeletonBar(width: 110, height: 12)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SkeletonBar(width: 90, height: 12)
                SkeletonBar(width: 200, height: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: Spacing.md) {
                SkeletonBar(width: 120, height: 12)
                HStack(alignment: .bottom, spacing: Spacing.xs) {
                    ForEach([60, 90, 70, 120, 100, 140, 110, 150], id: \.self) { height in
                        SkeletonBar(height: CGFloat(height)).frame(maxWidth: .infinity)
                    }
                }
            }
            .card()
        }
    }
}

struct DashboardBlockView: View {
    let block: DashboardBlock
    var hero = false

    /// Tables and lists run their rows edge to edge, so the card itself has no padding and the header carries it.
    private var isRows: Bool { block.error == nil && (block.type == .table || block.type == .list) }

    var body: some View {
        VStack(alignment: .leading, spacing: isRows ? 0 : CardMetrics.headerGap) {
            if block.type != .number || block.error != nil {
                SectionTitle(text: block.title) {
                    if block.truncated == true { Badge(text: String(localized: "Truncated")) }
                }
                .padding([.horizontal, .top], isRows ? CardMetrics.padding : 0)
                .padding(.bottom, isRows ? Spacing.xxs : 0)
            }
            if let error = block.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Color.bad)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                switch block.type {
                case .number: NumberBlock(block: block, hero: hero)
                case .line: LineBlock(block: block)
                case .bar: BarBlock(block: block)
                case .donut: DonutBlock(block: block)
                case .table: TableBlock(block: block)
                case .list: ListBlock(block: block)
                case .unknown: Text("Unsupported block").font(.footnote).foregroundStyle(Color.text3)
                }
            }
        }
        // maxHeight lets a grid row stretch every tile to the tallest one.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: isRows ? 0 : CardMetrics.padding)
    }
}

private struct NumberBlock: View {
    let block: DashboardBlock
    let hero: Bool

    var body: some View {
        let value = block.value ?? .null
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(block.title).font(hero ? .subheadline.weight(.medium) : .caption.weight(.medium)).foregroundStyle(Color.text2).lineLimit(1)
            Text(text(value))
                .font(hero ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: value.double ?? 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(_ value: JSONValue) -> String {
        if block.format == "money", let number = value.double { return ValueFormat.money(number, cents: hero ? abs(number) < 1_000 : false) }
        return ValueFormat.formatted(value, format: block.format)
    }
}

/// Shared helpers for chart blocks: x labels in French and y in the block's format.
private struct ChartPoint: Identifiable {
    let id: Int
    let series: String
    let x: String
    let label: String
    let y: Double
}

private extension DashboardBlock {
    var points: [ChartPoint] {
        var result: [ChartPoint] = []
        for series in series ?? [] {
            for point in series.points {
                result.append(ChartPoint(id: result.count, series: series.name, x: point.x.string ?? "", label: ValueFormat.axisLabel(point.x), y: point.y ?? 0))
            }
        }
        return result
    }

    var seriesNames: [String] { (series ?? []).map(\.name) }

    func axis(_ value: Double) -> String {
        switch format {
        case "money": ValueFormat.compactMoney(value)
        case "percent": ValueFormat.percent(value)
        default: ValueFormat.number(value)
        }
    }

    func full(_ value: Double) -> String {
        switch format {
        case "money": ValueFormat.money(value, cents: false)
        case "percent": ValueFormat.percent(value)
        default: ValueFormat.number(value)
        }
    }
}

private struct SeriesLegend: View {
    let names: [String]

    var body: some View {
        WrapLayout(spacing: Spacing.sm, lineSpacing: Spacing.xxs) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: Spacing.xxs) {
                    Circle().fill(ChartPalette.color(index)).frame(width: 8, height: 8)
                    Text(name).font(.caption).foregroundStyle(Color.text2)
                }
            }
        }
    }
}

private struct LineBlock: View {
    let block: DashboardBlock
    @State private var selected: String?
    @State private var plotWidth: CGFloat = 0
    /// Room one x label needs ("sept.", "14 mars").
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 32

    var body: some View {
        let points = block.points
        let names = block.seriesNames
        let multi = names.count > 1
        let order = Array(NSOrderedSet(array: points.map(\.x))) as? [String] ?? []
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !multi, let last = points.last {
                let first = points.first?.y ?? 0
                let shown = selected.flatMap { key in points.first { $0.x == key } } ?? last
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(block.full(shown.y)).font(.title3.bold().monospacedDigit()).foregroundStyle(Color.ink)
                        .contentTransition(.numericText(value: shown.y))
                    if selected == nil, first != 0 {
                        let delta = (last.y - first) / abs(first)
                        Text("\(delta >= 0 ? "+" : "")\(ValueFormat.percent(delta))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(delta >= 0 ? Color.good : Color.bad)
                    } else if selected != nil {
                        Text(shown.label).font(.caption).foregroundStyle(Color.text2)
                    }
                }
            }
            let values = points.map(\.y)
            let low = values.min() ?? 0, high = values.max() ?? 1
            let pad = max((high - low) * 0.15, abs(high) * 0.02, 1)
            let floor = low >= 0 && low - pad < 0 ? 0 : low - pad
            Chart(points) { point in
                if !multi {
                    AreaMark(x: .value("x", point.x), yStart: .value("base", floor), yEnd: .value("y", point.y))
                        .foregroundStyle(LinearGradient(colors: [Color.accent.opacity(0.25), Color.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                if let selected, point.x == selected {
                    PointMark(x: .value("x", point.x), y: .value("y", point.y))
                        .foregroundStyle(by: .value("Series", point.series))
                        .symbolSize(50)
                }
            }
            .chartForegroundStyleScale(domain: names, range: names.indices.map(ChartPalette.color))
            .chartLegend(.hidden)
            .chartYScale(domain: floor...(high + pad))
            .chartXAxis {
                AxisMarks(values: AxisTicks.keys(order, width: plotWidth, labelWidth: labelWidth, cap: 6, keepLast: true)) { value in
                    AxisValueLabel(collisionResolution: .greedy(minimumSpacing: Spacing.xxs)) {
                        if let key = value.as(String.self) { Text(points.first { $0.x == key }?.label ?? key) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(Color.line)
                    AxisValueLabel { if let y = value.as(Double.self) { Text(block.axis(y)) } }
                }
            }
            .chartXSelection(value: $selected)
            .frame(minHeight: DashboardMetrics.chartHeight, maxHeight: .infinity)
            // The top y label is centred on the top grid line, so it needs room under the headline figure.
            .padding(.top, Spacing.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
            if multi { SeriesLegend(names: names) }
        }
    }
}

/// X labels thinned evenly so they never collide, whatever the width and text size.
private enum AxisTicks {
    static func keys(_ keys: [String], width: CGFloat, labelWidth: CGFloat, cap: Int = .max, keepLast: Bool) -> [String] {
        let fit = width > 0 ? Int(width / labelWidth) : keys.count
        let limit = max(2, min(cap, fit))
        guard keys.count > limit else { return keys }
        let step = Int((Double(keys.count) / Double(limit)).rounded(.up))
        var indices = Array(stride(from: 0, to: keys.count, by: step))
        let last = keys.count - 1
        // Keep the latest period labelled without crowding it against the previous tick.
        if keepLast, let previous = indices.last, previous != last {
            if last - previous < step / 2 + 1 { indices.removeLast() }
            indices.append(last)
        }
        return indices.map { keys[$0] }
    }
}

private struct BarBlock: View {
    let block: DashboardBlock
    @State private var selected: String?
    @State private var plotWidth: CGFloat = 0
    /// Room one x label needs ("sept.", "14 mars").
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 32

    var body: some View {
        let points = block.points
        let names = block.seriesNames
        let order = Array(NSOrderedSet(array: points.map(\.x))) as? [String] ?? []
        let totals = Dictionary(grouping: points, by: \.x).mapValues { $0.reduce(0) { $0 + $1.y } }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let selected, let total = totals[selected] {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(block.full(total)).font(.title3.bold().monospacedDigit()).foregroundStyle(Color.ink)
                    Text(points.first { $0.x == selected }?.label ?? selected).font(.caption).foregroundStyle(Color.text2)
                }
            } else if let total = Optional(totals.values.reduce(0, +)), total != 0 {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(block.full(total)).font(.title3.bold().monospacedDigit()).foregroundStyle(Color.ink)
                    Text("in total").font(.caption).foregroundStyle(Color.text2)
                }
            }
            Chart(points) { point in
                BarMark(x: .value("x", point.x), y: .value("y", point.y), width: .ratio(0.62))
                    .foregroundStyle(by: .value("Series", point.series))
                    .clipShape(RoundedRectangle(cornerRadius: names.count > 1 ? 2 : 5, style: .continuous))
                    .opacity(selected == nil || selected == point.x ? 1 : 0.35)
            }
            .chartForegroundStyleScale(domain: names, range: names.indices.map(ChartPalette.color))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: AxisTicks.keys(order, width: plotWidth, labelWidth: labelWidth, keepLast: false)) { value in
                    AxisValueLabel(collisionResolution: .greedy(minimumSpacing: Spacing.xxs)) {
                        if let key = value.as(String.self) { Text(points.first { $0.x == key }?.label ?? key) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(Color.line)
                    AxisValueLabel { if let y = value.as(Double.self) { Text(block.axis(y)) } }
                }
            }
            .chartXSelection(value: $selected)
            .frame(minHeight: DashboardMetrics.chartHeight, maxHeight: .infinity)
            // The top y label is centred on the top grid line, so it needs room under the headline figure.
            .padding(.top, Spacing.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
            .animation(.snappy(duration: 0.2), value: selected)
            if names.count > 1 { SeriesLegend(names: names) }
        }
    }
}

/// The ring grows into the room a taller neighbour gives the tile (up to `donutMaxSize`), so a stretched
/// card is filled by the chart instead of leaving a band of empty space.
private struct DonutBlock: View {
    let block: DashboardBlock
    @State private var room: CGSize = .zero

    private var ring: CGFloat {
        let fit = min(room.height, room.width * 0.45)
        return min(max(fit, DashboardMetrics.donutSize), DashboardMetrics.donutMaxSize)
    }

    var body: some View {
        let points = block.points
        let total = points.reduce(0) { $0 + max($1.y, 0) }
        let labels = points.map(\.label)
        HStack(alignment: .center, spacing: Spacing.md) {
            Chart(points) { point in
                SectorMark(angle: .value("y", max(point.y, 0)), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("x", point.label))
            }
            .chartForegroundStyleScale(domain: labels, range: labels.indices.map(ChartPalette.color))
            .chartLegend(.hidden)
            .chartBackground { proxy in
                GeometryReader { geometry in
                    if let frame = proxy.plotFrame {
                        let rect = geometry[frame]
                        VStack(spacing: 0) {
                            Text(block.format == "money" ? ValueFormat.compactMoney(total) : ValueFormat.number(total))
                                .font((ring > DashboardMetrics.donutSize ? Font.title3.bold() : .headline).monospacedDigit()).foregroundStyle(Color.ink)
                            Text("total").font(.caption2).foregroundStyle(Color.text3)
                        }
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: ring, height: ring)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(points.prefix(6).enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        RoundedRectangle(cornerRadius: 3).fill(ChartPalette.color(index)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(point.label).font(.caption.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                            Text("\(block.full(point.y)) · \(ValueFormat.percent(total > 0 ? point.y / total : 0))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
    }
}

private struct TableBlock: View {
    let block: DashboardBlock
    private let home = FilesHomeStore.shared

    var body: some View {
        let columns = block.columns ?? []
        let idIndex = columns.firstIndex(of: "id")
        let shown = columns.indices.filter { $0 != idIndex }
        let collection = block.collection.flatMap(home.collection)
        let titleIndex = shown.first
        let numberIndex = shown.last { index in
            let type = collection?.column(columns[index])?.type
            return type == .money || type == .number || (type == nil && (block.rows ?? []).contains { $0.indices.contains(index) && Self.isNumber($0[index]) })
        }
        let chipIndex = shown.first { collection?.column(columns[$0])?.type == .select }
        let others = shown.filter { $0 != titleIndex && $0 != numberIndex && $0 != chipIndex }.prefix(2)
        VStack(spacing: 0) {
            ForEach(Array((block.rows ?? []).enumerated()), id: \.offset) { offset, row in
                let id = idIndex.flatMap { row.indices.contains($0) ? row[$0].string : nil }
                Group {
                    if let id, let target = block.collection {
                        NavigationLink(value: FilesRoute.row(collection: target, id: id)) { line(row, columns, collection, titleIndex, numberIndex, chipIndex, Array(others), linked: true) }
                            .buttonStyle(RowPressStyle())
                    } else {
                        line(row, columns, collection, titleIndex, numberIndex, chipIndex, Array(others), linked: false)
                    }
                }
                if offset < (block.rows?.count ?? 0) - 1 { Divider().overlay(Color.line).padding(.leading, CardMetrics.rowInset) }
            }
        }
        .padding(.bottom, Spacing.xxs)
    }

    private static func isNumber(_ value: JSONValue) -> Bool { if case .number = value { true } else { false } }

    private func cell(_ row: [JSONValue], _ index: Int?) -> JSONValue {
        guard let index, row.indices.contains(index) else { return .null }
        return row[index]
    }

    private func format(_ value: JSONValue, column: DataColumn?) -> String {
        if let column {
            if [.date, .datetime].contains(column.type), let date = value.string.flatMap(ValueFormat.parseDate) { return ValueFormat.relativeDay(date) }
            return ValueFormat.text(value, column: column)
        }
        return ValueFormat.formatted(value, format: Self.isNumber(value) ? block.format : nil)
    }

    private func line(_ row: [JSONValue], _ columns: [String], _ collection: DataCollection?, _ titleIndex: Int?, _ numberIndex: Int?,
                      _ chipIndex: Int?, _ others: [Int], linked: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(cell(row, titleIndex).string ?? "—").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                let details = others.map { format(cell(row, $0), column: collection?.column(columns[$0])) }.filter { $0 != "—" && !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.xs)
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                if let numberIndex {
                    Text(format(cell(row, numberIndex), column: collection?.column(columns[numberIndex])))
                        .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                }
                if let chipIndex, let column = collection?.column(columns[chipIndex]), let option = ValueFormat.option(cell(row, chipIndex).string, in: column) {
                    OptionChip(option: option, compact: true)
                }
            }
            if linked { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color.text3) }
        }
        .padding(.horizontal, CardMetrics.rowInset)
        .padding(.vertical, CardMetrics.rowVertical)
        .contentShape(Rectangle())
    }
}

private struct ListBlock: View {
    let block: DashboardBlock

    var body: some View {
        let items = block.items ?? []
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Group {
                    if let id = item.id, let collection = block.collection {
                        NavigationLink(value: FilesRoute.row(collection: collection, id: id)) { line(item, index: index, linked: true) }
                            .buttonStyle(RowPressStyle())
                    } else {
                        line(item, index: index, linked: false)
                    }
                }
                if index < items.count - 1 { Divider().overlay(Color.line).padding(.leading, CardMetrics.rowInset + Self.dot + Spacing.sm) }
            }
        }
        .padding(.bottom, Spacing.xxs)
    }

    private static let dot: CGFloat = 10

    private func line(_ item: DashboardBlock.Item, index: Int, linked: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Circle().fill(ChartPalette.color(index)).frame(width: Self.dot, height: Self.dot)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.text2).lineLimit(1) }
            }
            Spacer(minLength: Spacing.xs)
            if let value = item.value {
                Text(ValueFormat.formatted(value, format: block.format)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
            }
            if linked { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color.text3) }
        }
        .padding(.horizontal, CardMetrics.rowInset)
        .padding(.vertical, CardMetrics.rowVertical)
        .contentShape(Rectangle())
    }
}

/// Wraps its children on several lines (legends, chips).
struct WrapLayout: Layout {
    var spacing: CGFloat = Spacing.xs
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + (lineSpacing ?? spacing / 1.5)
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + (lineSpacing ?? spacing / 1.5)
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Grid for dashboard blocks: as many columns of at least `minColumnWidth` as the width allows (capped by
/// `maxColumns` and the item count), never wider than the proposal, every tile of a row as tall as the tallest,
/// and a short last row sharing the full width.
struct DashboardGrid: Layout {
    var minColumnWidth: CGFloat
    var maxColumns: Int
    var spacing: CGFloat = DashboardMetrics.gutter

    func columns(for width: CGFloat, count: Int) -> Int {
        let fit = Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))
        return max(1, min(maxColumns, fit, count))
    }

    private struct Row {
        var range: Range<Int>
        var itemWidth: CGFloat
        var height: CGFloat
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        let perRow = columns(for: width, count: subviews.count)
        var rows: [Row] = []
        var start = 0
        while start < subviews.count {
            let end = min(start + perRow, subviews.count)
            let count = CGFloat(end - start)
            let itemWidth = max(0, (width - spacing * (count - 1)) / count)
            let height = subviews[start..<end].map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            rows.append(Row(range: start..<end, itemWidth: itemWidth, height: height))
            start = end
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minColumnWidth
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.range {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: row.itemWidth, height: row.height))
                x += row.itemWidth + spacing
            }
            y += row.height + spacing
        }
    }
}
