import SwiftUI

/// A collection as a native table: columns follow the schema, sorting and search run on the gateway,
/// cells edit in place and the selected row opens in the inspector.
struct CollectionTableView: View {
    let collectionId: String
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var store: CollectionStore
    @State private var selection: Set<DataRow.ID> = []
    /// A row opened from a link: selected and shown in the inspector even when it is not among the loaded rows.
    @State private var linkedRow: DataRow.ID?
    /// `column:asc|desc`, the gateway's sort.
    @State private var sort: String?
    @State private var search = ""
    @State private var showsInspector = false
    @State private var editing: (row: DataRow, column: DataColumn)?
    @State private var failure: String?
    @State private var confirmArchive = false
    @FocusState private var searchFocused: Bool
    private let home = FilesHomeStore.shared

    init(collectionId: String) {
        self.collectionId = collectionId
        _store = State(initialValue: CollectionStore(collectionId: collectionId))
    }

    private var collection: DataCollection? { home.collection(collectionId) }

    private var columns: [DataColumn] {
        guard let collection else { return [] }
        let visible = collection.visibleColumns
        let title = visible.filter { $0.name == collection.titleColumn }
        return title + visible.filter { $0.name != collection.titleColumn }
    }

    private var selectedRowId: DataRow.ID? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return id
    }

    /// The selected rows the table shows: actions never reach rows hidden by a search or a filter.
    private var visibleSelection: Set<DataRow.ID> { selection.filter { store.row($0) != nil } }

    var body: some View {
        table
            .navigationTitle(collection.map { "\($0.emoji.map { "\($0) " } ?? "")\($0.label)" } ?? "")
            .navigationSubtitle(countLabel)
            .searchable(text: $search, prompt: "Search in \(collection?.label ?? String(localized: "the collection"))")
            .searchFocused($searchFocused)
            .toolbar { toolbar }
            .inspector(isPresented: $showsInspector) {
                Group {
                    if let id = selectedRowId {
                        RowDetailView(collectionId: collectionId, rowId: id, seed: store.row(id)) { row in store.replace(row) }
                            .id(id)
                    } else {
                        ContentUnavailableView(selection.isEmpty ? String(localized: "No selection") : String(localized: "\(selection.count) items"),
                                               systemImage: "sidebar.right",
                                               description: Text(selection.isEmpty ? String(localized: "Choose a row to see its detail and history.") : String(localized: "Right-click to archive the selection.")))
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let editing {
                    FieldEditorSheet(column: editing.column, value: editing.row[editing.column.name], refTitle: editing.row.refs?[editing.column.name]) { value in
                        await save(editing.row, editing.column, value)
                    }
                    .frame(minWidth: 420, minHeight: 360)
                }
            }
            .alert("Couldn't make the change", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
            .confirmationDialog(visibleSelection.count > 1 ? String(localized: "Archive \(visibleSelection.count) items?") : String(localized: "Archive this item?"), isPresented: $confirmArchive) {
                Button("Archive", role: .destructive) {
                    let ids = visibleSelection
                    Task { await archive(ids) }
                }
            } message: {
                Text("They disappear from lists and dashboards. Nothing is deleted.")
            }
            .task(id: navigator.refreshTick) {
                store.attach(session.api)
                if collection == nil {
                    home.attach(session.api)
                    await home.load()
                }
                if sort == nil { sort = collection?.defaultSort }
                await store.reload()
                selectPendingRow()
            }
            .task(id: search) {
                guard search != store.query.search else { return }
                try? await Task.sleep(for: .milliseconds(250))
                store.query.search = search
                await store.reload()
            }
            .onChange(of: sort) { _, sort in
                guard sort != store.query.sort else { return }
                store.query.sort = sort
                Task { await store.reload() }
            }
            .onChange(of: selection) { old, new in
                if new.count == 1, old.isEmpty { showsInspector = true }
                if let linkedRow, !new.contains(linkedRow) { self.linkedRow = nil }
            }
            .onChange(of: store.rows) { _, _ in pruneSelection() }
            .onChange(of: navigator.pendingRow) { _, _ in selectPendingRow() }
            .onChange(of: navigator.searchFocus) { _, _ in searchFocused = true }
    }

    private var countLabel: String {
        if store.groupBy != nil, let groups = store.groups {
            let count = groups.groups.count
            return "\(String(localized: "\(groups.total.count) items")) · \(String(localized: "\(count) groups"))"
        }
        let total = store.total ?? store.rows.count
        return String(localized: "\(total) items")
    }

    // MARK: Table

    @ViewBuilder
    private var table: some View {
        if let grouping = DataGrouping.find(store.groupBy, in: collection) {
            CollectionGroupsTable(grouping: grouping, groups: store.groups, summed: DataGrouping.summed(collection),
                                  error: store.error, retry: { Task { await store.reload() } }) { group in
                store.open(group, of: grouping)
                Task { await store.reload() }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        CollectionGrid(columns: columns, titleColumn: collection?.titleColumn, rows: store.rows,
                       selection: $selection, sort: $sort, actions: gridActions)
            .overlay {
                if store.loaded && store.rows.isEmpty, let error = store.error {
                    VStack(spacing: 12) {
                        WorkspaceEmptyState(symbol: "icloud.slash", title: String(localized: "Couldn't load the collection"), message: error)
                        Button("Try again") { Task { await store.reload() } }
                    }
                } else if store.loaded && store.rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? String(localized: "Empty collection") : String(localized: "No results"), systemImage: "tablecells",
                                           description: Text(search.isEmpty ? String(localized: "Add a row with +.") : String(localized: "Try other words.")))
                } else if !store.loaded {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !store.rows.isEmpty, let message = store.error ?? store.pageError.map({ String(localized: "Next rows unavailable: \($0)") }) {
                    StaleBanner(message: message) {
                        if store.pageError != nil, store.error == nil { store.loadMore() } else { Task { await store.reload() } }
                    }
                    .padding(8)
                }
            }
    }

    private var gridActions: CollectionGridActions {
        CollectionGridActions(
            save: { row, column, value in Task { _ = await save(row, column, value) } },
            edit: { row, column in editing = (row, column) },
            open: { ids in
                selection = ids
                showsInspector = true
            },
            copy: { ids in copy(ids) },
            archive: { ids in
                selection = ids
                confirmArchive = !ids.isEmpty
            },
            delete: { confirmArchive = !visibleSelection.isEmpty },
            rowShown: { row in store.rowAppeared(row) },
            reject: { message in failure = message })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let drilled = store.drilled {
                Button {
                    store.closeDrilledGroup()
                    Task { await store.reload() }
                } label: {
                    Label(drilled.label, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                }
                .help("Back to all rows")
            }
            if let collection, !DataGrouping.options(collection).isEmpty {
                groupMenu(collection)
            }
            if let collection, !filterColumns(collection).isEmpty {
                filterMenu(collection)
            }
            Button { Task { await createRow() } } label: { Label("New row", systemImage: "plus") }
                .help("New row")
            Button { showsInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the detail")
        }
    }

    private func filterColumns(_ collection: DataCollection) -> [DataColumn] {
        collection.visibleColumns.filter { $0.type == .select && !($0.options ?? []).isEmpty }
    }

    private func filterMenu(_ collection: DataCollection) -> some View {
        Menu {
            ForEach(filterColumns(collection)) { column in
                Section(column.label) {
                    ForEach(column.options ?? []) { option in
                        let filter = DataFilter(column: column.name, op: .eq, value: option.value)
                        Toggle(option.display, isOn: Binding(
                            get: { store.query.filters.contains(filter) },
                            set: { on in
                                store.query.filters.removeAll { $0.column == column.name }
                                if on { store.query.filters.append(filter) }
                                Task { await store.reload() }
                            }))
                    }
                }
            }
            if !store.query.filters.isEmpty {
                Divider()
                Button("Remove Filters") {
                    store.clearFilters()
                    Task { await store.reload() }
                }
            }
        } label: {
            Label("Filter", systemImage: store.query.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter")
    }

    private func groupMenu(_ collection: DataCollection) -> some View {
        let current = DataGrouping.find(store.groupBy, in: collection)
        return Menu {
            Toggle("No Grouping", isOn: Binding(get: { current == nil }, set: { if $0 { setGrouping(nil) } }))
            Divider()
            ForEach(DataGrouping.options(collection)) { grouping in
                Toggle(grouping.title, isOn: Binding(get: { current == grouping }, set: { if $0 { setGrouping(grouping) } }))
            }
        } label: {
            Label("Group", systemImage: current == nil ? "square.stack.3d.up" : "square.stack.3d.up.fill")
        }
        .help(current.map { String(localized: "Grouped by \($0.title.lowercased())") } ?? String(localized: "Group and total"))
    }

    private func setGrouping(_ grouping: DataGrouping?) {
        store.groupBy = grouping?.by
        selection = []
        Task { await store.reload() }
    }

    // MARK: Actions

    private func selectPendingRow() {
        guard let id = navigator.pendingRow else { return }
        navigator.pendingRow = nil
        linkedRow = id
        selection = [id]
        showsInspector = true
    }

    /// Rows a search, a filter or an archive took out of the table leave the selection too.
    private func pruneSelection() {
        let kept = selection.filter { store.row($0) != nil || $0 == linkedRow }
        if kept != selection { selection = kept }
    }

    private func save(_ row: DataRow, _ column: DataColumn, _ value: JSONValue) async -> Bool {
        guard (store.row(row.id) ?? row)[column.name] != value else { return true }
        if let message = await store.update(row.id, column.name, value) {
            failure = message
            return false
        }
        return true
    }

    private func createRow() async {
        guard let collection else { return }
        do {
            let row = try await session.api.createRow(collection: collectionId, values: [collection.titleColumn: .string(String(localized: "New item"))])
            await store.reload()
            selection = [row.id]
            showsInspector = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func archive(_ ids: Set<String>) async {
        for id in ids {
            do {
                let row = try await session.api.archiveRow(collection: collectionId, id: id, archived: true)
                store.replace(row)
            } catch {
                failure = error.localizedDescription
            }
        }
        selection = []
    }

    private func copy(_ ids: Set<String>) {
        let rows = store.rows.filter { ids.contains($0.id) }
        let header = columns.map(\.label).joined(separator: "\t")
        let lines = rows.map { row in
            columns.map { ValueFormat.text(row[$0.name], column: $0, refTitle: row.refs?[$0.name]) }.joined(separator: "\t")
        }
        PlatformPasteboard.copy(([header] + lines).joined(separator: "\n"))
    }
}
