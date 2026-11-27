import SwiftUI

/// Which columns a row shows in a list: title, a trailing figure, a status chip and up to two details.
struct RowLayout {
    let trailing: DataColumn?
    let chip: DataColumn?
    let details: [DataColumn]

    init(_ collection: DataCollection?) {
        let columns = (collection?.visibleColumns ?? []).filter { $0.name != collection?.titleColumn }
        let trailing = columns.first { $0.type == .money } ?? columns.first { $0.type == .number && !$0.isComputed }
        let chip = columns.first { $0.type == .select }
        self.trailing = trailing
        self.chip = chip
        let rest = columns.filter { $0 != trailing && $0 != chip }
        let preferred = rest.filter { [.ref, .date, .datetime].contains($0.type) } + rest.filter { [.text, .multiselect].contains($0.type) }
        details = Array(preferred.prefix(2))
    }
}

struct CollectionView: View {
    let collectionId: String
    @Environment(SessionStore.self) private var session
    @State private var store: CollectionStore
    @State private var search = ""
    @State private var debouncer = Debouncer()
    private let home = FilesHomeStore.shared

    init(collectionId: String) {
        self.collectionId = collectionId
        _store = State(initialValue: CollectionStore(collectionId: collectionId))
    }

    private var collection: DataCollection? { home.collection(collectionId) }

    var body: some View {
        let layout = RowLayout(collection)
        let signed = layout.trailing.map { column in store.rows.contains { ($0[column.name].double ?? 0) < 0 } } ?? false
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                chips
                summary
                if !store.loaded {
                    SkeletonRows(count: 8)
                } else if let grouping = DataGrouping.find(store.groupBy, in: collection), let groups = store.groups {
                    groupList(groups, grouping)
                } else if store.rows.isEmpty {
                    WorkspaceEmptyState(symbol: "tray", title: store.query == DataQuery() ? String(localized: "Empty collection") : String(localized: "No results"),
                                        message: store.query == DataQuery() ? String(localized: "Bots add items here.") : String(localized: "Try another filter."),
                                        mascot: store.query == DataQuery() ? .idle : nil)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                            NavigationLink(value: FilesRoute.row(collection: collectionId, id: row.id)) {
                                DataRowCell(row: row, collection: collection, layout: layout, signed: signed)
                            }
                            .buttonStyle(RowPressStyle())
                            .onAppear { store.rowAppeared(row) }
                            if index < store.rows.count - 1 { Divider().overlay(Color.line).padding(.leading, 16) }
                        }
                        if store.nextCursor != nil {
                            ProgressView().padding(.vertical, 16).frame(maxWidth: .infinity)
                        }
                    }
                    .groupCard()
                }
                if let error = store.error {
                    StaleBanner(message: error) { Task { await store.reload() } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Color.canvas)
        .navigationTitle(collection.map { "\($0.emoji ?? "") \($0.label)".trimmingCharacters(in: .whitespaces) } ?? collectionId)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .onChange(of: search) { _, value in debouncer.send(value) }
        .onChange(of: debouncer.value) { _, value in
            store.query.search = value
            Task { await store.reload() }
        }
        .refreshable { await store.reload() }
        .task {
            store.attach(session.api)
            if collection == nil {
                home.attach(session.api)
                await home.load()
            }
            await store.reload()
        }
    }

    // MARK: Chips

    private var sortColumn: (column: String, descending: Bool) {
        let raw = store.query.sort ?? collection?.defaultSort ?? "\(collection?.titleColumn ?? ""):asc"
        let parts = raw.split(separator: ":").map(String.init)
        return (parts.first ?? "", parts.count > 1 && parts[1] == "desc")
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if store.groupBy == nil { sortMenu }
                groupMenu
                if let drilled = store.drilled {
                    Button {
                        Haptics.selection()
                        store.closeDrilledGroup()
                        Task { await store.reload() }
                    } label: {
                        FilterChip(title: drilled.label, symbol: "xmark", active: true)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(collection?.visibleColumns.filter { $0.type == .select && !($0.options ?? []).isEmpty } ?? []) { column in
                    selectMenu(column)
                }
                ForEach(collection?.visibleColumns.filter { $0.type == .bool } ?? []) { column in
                    let active = store.query.filters.contains { $0.column == column.name }
                    Button {
                        Haptics.selection()
                        setFilter(column.name, active ? nil : DataFilter(column: column.name, op: .eq, value: "1"))
                    } label: {
                        FilterChip(title: column.label, symbol: active ? "checkmark" : nil, active: active)
                    }
                    .buttonStyle(.plain)
                }
                if !store.query.filters.isEmpty {
                    Button {
                        Haptics.selection()
                        store.clearFilters()
                        Task { await store.reload() }
                    } label: {
                        FilterChip(title: String(localized: "Clear"), symbol: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var sortMenu: some View {
        let current = sortColumn
        let sortable = collection?.visibleColumns.filter { ![.longtext, .multiselect, .file, .url].contains($0.type) } ?? []
        return Menu {
            ForEach(sortable) { column in
                Button {
                    let descending = current.column == column.name ? !current.descending : [.date, .datetime, .money, .number].contains(column.type)
                    store.query.sort = "\(column.name):\(descending ? "desc" : "asc")"
                    Task { await store.reload() }
                } label: {
                    if current.column == column.name {
                        Label(column.label, systemImage: current.descending ? "arrow.down" : "arrow.up")
                    } else {
                        Text(column.label)
                    }
                }
            }
        } label: {
            FilterChip(title: collection?.column(current.column)?.label ?? String(localized: "Sort"), symbol: current.descending ? "arrow.down" : "arrow.up")
        }
    }

    private var groupMenu: some View {
        let current = DataGrouping.find(store.groupBy, in: collection)
        return Menu {
            Button("No grouping") { setGrouping(nil) }
            Divider()
            ForEach(DataGrouping.options(collection)) { grouping in
                Button {
                    setGrouping(grouping)
                } label: {
                    if current == grouping { Label(grouping.title, systemImage: "checkmark") } else { Text(grouping.title) }
                }
            }
        } label: {
            FilterChip(title: current?.title ?? String(localized: "Group"), symbol: "square.stack.3d.up", active: current != nil)
        }
    }

    private func setGrouping(_ grouping: DataGrouping?) {
        Haptics.selection()
        store.groupBy = grouping?.by
        Task { await store.reload() }
    }

    private func groupList(_ groups: DataGroups, _ grouping: DataGrouping) -> some View {
        let lead = DataGrouping.summed(collection).first
        return LazyVStack(spacing: 0) {
            ForEach(Array(groups.groups.enumerated()), id: \.element.id) { index, group in
                Button {
                    Haptics.tap()
                    store.open(group, of: grouping)
                    Task { await store.reload() }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(grouping.label(group)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                            Text("\(group.count) items").font(.caption).foregroundStyle(Color.text2)
                        }
                        Spacer(minLength: 8)
                        if let lead, let sum = group.sums[lead.name] {
                            Text(ValueFormat.money(sum)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color.text3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                if index < groups.groups.count - 1 { Divider().overlay(Color.line).padding(.leading, 16) }
            }
        }
        .groupCard()
    }

    private func selectMenu(_ column: DataColumn) -> some View {
        let active = store.query.filters.first { $0.column == column.name }
        let option = active.flatMap { ValueFormat.option($0.value, in: column) }
        return Menu {
            Button("All") { setFilter(column.name, nil) }
            Divider()
            ForEach(column.options ?? []) { item in
                Button {
                    setFilter(column.name, DataFilter(column: column.name, op: .eq, value: item.value))
                } label: {
                    if active?.value == item.value { Label(item.display, systemImage: "checkmark") } else { Text(item.display) }
                }
            }
        } label: {
            FilterChip(title: option?.display ?? column.label, symbol: option == nil ? "chevron.down" : nil, active: option != nil,
                       tint: option.map(ValueFormat.color(for:)))
        }
    }

    private func setFilter(_ column: String, _ filter: DataFilter?) {
        store.query.filters.removeAll { $0.column == column }
        if let filter { store.query.filters.append(filter) }
        Task { await store.reload() }
    }

    @ViewBuilder
    private var summary: some View {
        if store.groupBy != nil, let groups = store.groups {
            let lead = DataGrouping.summed(collection).first
            HStack(spacing: 4) {
                Text("\(groups.total.count) items")
                Text("· \(groups.groups.count) groups")
                if let lead, let sum = groups.total.sums[lead.name] {
                    Spacer(minLength: 8)
                    Text("\(lead.label): \(ValueFormat.money(sum))").monospacedDigit().foregroundStyle(Color.text2)
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.text3)
        } else if let total = store.total ?? (store.loaded ? store.rows.count : nil) {
            let sort = sortColumn
            HStack(spacing: 4) {
                Text("\(total) items")
                if let label = collection?.column(sort.column)?.label {
                    Text("· sorted by \(label.lowercased())")
                    Image(systemName: sort.descending ? "arrow.down" : "arrow.up").font(.caption2.weight(.bold))
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.text3)
        }
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.chip : Color.clear)
    }
}

struct DataRowCell: View {
    let row: DataRow
    let collection: DataCollection?
    let layout: RowLayout
    var signed = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title.isEmpty ? String(localized: "Untitled") : row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                let details = layout.details.compactMap(detail)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.text2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if let column = layout.trailing, !row[column.name].isNull {
                    Text(ValueFormat.text(row[column.name], column: column))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(amountColor(column))
                        .lineLimit(1)
                }
                if let column = layout.chip, let option = ValueFormat.option(row[column.name].string, in: column) {
                    OptionChip(option: option, compact: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Incomes in green only where amounts are signed (transfers), not for invoices.
    private func amountColor(_ column: DataColumn) -> Color {
        guard signed, column.type == .money, let value = row[column.name].double, value > 0 else { return Color.ink }
        return Color.good
    }

    private func detail(_ column: DataColumn) -> String? {
        let value = row[column.name]
        guard !value.isNull else { return nil }
        switch column.type {
        case .date, .datetime:
            return value.string.flatMap(ValueFormat.parseDate).map { ValueFormat.relativeDay($0) }
        case .ref, .refs:
            return row.refs?[column.name] ?? (column.type == .ref ? value.string : nil)
        default:
            let text = ValueFormat.text(value, column: column)
            return text == "—" || text.isEmpty ? nil : text
        }
    }
}
