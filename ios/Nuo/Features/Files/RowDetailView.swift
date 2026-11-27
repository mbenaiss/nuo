import SwiftUI

struct RowDetailView: View {
    let collectionId: String
    let rowId: String
    /// The row as the list around it shows it: edits made there show here.
    var seed: DataRow?
    /// Edits, archiving and reloads of this screen, for the list around it.
    var onRowChange: (DataRow) -> Void = { _ in }
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var store: RowStore
    @State private var editing: DataColumn?
    @State private var confirmArchive = false
    @State private var pendingRevert: DataChange?
    @State private var showsAllHistory = false
    private let home = FilesHomeStore.shared

    init(collectionId: String, rowId: String, seed: DataRow?, onRowChange: @escaping (DataRow) -> Void = { _ in }) {
        self.collectionId = collectionId
        self.rowId = rowId
        self.seed = seed
        self.onRowChange = onRowChange
        _store = State(initialValue: RowStore(collectionId: collectionId, rowId: rowId, seed: seed))
    }

    private var collection: DataCollection? { home.collection(collectionId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if store.row != nil, let error = store.error {
                    StaleBanner(message: error) { Task { await store.load() } }
                }
                if let row = store.row {
                    header(row)
                    fields(row)
                    computed(row)
                    historySection
                    archiveButton(row)
                } else if let error = store.error {
                    WorkspaceEmptyState(symbol: "exclamationmark.triangle", title: String(localized: "Not found"), message: error)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBar(width: 220, height: 24)
                        SkeletonBar(width: 120, height: 16)
                        SkeletonRows(count: 6)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle(collection?.label ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .sheet(item: $editing) { column in
            if let row = store.row, column.type == .file {
                FileFieldSheet(column: column, files: ValueFormat.files(row[column.name])) { name, data, contentType in
                    await store.attach(column.name, name: name, data: data, contentType: contentType)
                }
                .alert("Could not edit", isPresented: failureShown) {
                    Button("OK", role: .cancel) {}
                } message: { Text(store.failure ?? "") }
            } else if let row = store.row {
                FieldEditorSheet(column: column, value: row[column.name], refTitle: row.refs?[column.name]) { value in
                    await store.update(column.name, value)
                }
                .alert("Could not edit", isPresented: failureShown) {
                    Button("OK", role: .cancel) {}
                } message: { Text(store.failure ?? "") }
            }
        }
        .alert("Could not edit", isPresented: Binding(get: { editing == nil && store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.failure ?? "") }
        .confirmationDialog(store.row?.archivedAt == nil ? String(localized: "Archive this item?") : String(localized: "Restore this item?"),
                            isPresented: $confirmArchive, titleVisibility: .visible) {
            if store.row?.archivedAt == nil {
                Button("Archive", role: .destructive) {
                    Task { if await store.setArchived(true) { dismiss() } }
                }
            } else {
                Button("Restore") { Task { _ = await store.setArchived(false) } }
            }
        } message: {
            Text(store.row?.archivedAt == nil ? String(localized: "It disappears from lists and dashboards. Nothing is deleted: you can restore it from the history.") : String(localized: "It comes back in the lists."))
        }
        .confirmationDialog("Undo this change?", isPresented: Binding(get: { pendingRevert != nil }, set: { if !$0 { pendingRevert = nil } }),
                            titleVisibility: .visible) {
            Button("Restore the old values") {
                guard let change = pendingRevert else { return }
                Task { await store.revert(change) }
            }
        } message: {
            if let change = pendingRevert { Text(changeSummary(change)) }
        }
        .task(id: rowId) {
            store.attach(session.api)
            if collection == nil {
                home.attach(session.api)
                await home.loadIfStale()
            }
            await store.load()
        }
        .onChange(of: seed) { _, seed in
            guard let seed, seed != store.row else { return }
            store.adopt(seed)
            Task { await store.load() }
        }
        .onChange(of: store.row) { _, row in
            if let row, row != seed { onRowChange(row) }
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })
    }

    // MARK: Header

    private func header(_ row: DataRow) -> some View {
        let layout = RowLayout(collection)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let chip = layout.chip, let option = ValueFormat.option(row[chip.name].string, in: chip) {
                    Button { editing = chip } label: { OptionChip(option: option) }.buttonStyle(.plain)
                }
                if row.archivedAt != nil { Badge(text: String(localized: "Archived"), tint: Color.text2, fill: Color.chip) }
            }
            Text(row.title.isEmpty ? String(localized: "Untitled") : row.title)
                .font(.title2.bold())
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let hero = collection?.visibleColumns.last(where: { $0.type == .money && $0.isComputed }) ?? layout.trailing,
               let value = row[hero.name].double {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ValueFormat.money(value))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText(value: value))
                    Text(hero.label).font(.subheadline).foregroundStyle(Color.text2)
                }
            }
            Text("Edited \(row.updatedAt.relativeLabel)").font(.caption).foregroundStyle(Color.text3)
        }
    }

    // MARK: Fields

    private func fields(_ row: DataRow) -> some View {
        let columns = (collection?.visibleColumns ?? []).filter { !$0.isComputed }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Details"))
            VStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    fieldRow(column, row: row)
                    if index < columns.count - 1 { Divider().overlay(Color.line).padding(.leading, 16) }
                }
            }
            .groupCard()
        }
    }

    @ViewBuilder
    private func fieldRow(_ column: DataColumn, row: DataRow) -> some View {
        let value = row[column.name]
        if column.type == .bool {
            Toggle(isOn: Binding(get: { value.bool ?? false }, set: { new in Task { await store.update(column.name, .bool(new)) } })) {
                Text(column.label).font(.subheadline).foregroundStyle(Color.text2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            Button {
                Haptics.tap()
                editing = column
            } label: {
                FieldLine(column: column, value: value, refTitle: row.refs?[column.name], saving: store.saving.contains(column.name), editable: true)
            }
            .buttonStyle(RowPressStyle())
            .contextMenu {
                if column.type == .url, let url = value.string.flatMap(URL.init(string:)) {
                    Button { openURL(url) } label: { Label("Open link", systemImage: "safari") }
                }
                if column.type == .ref, let target = column.ref, let id = value.string {
                    NavigationLink(value: FilesRoute.row(collection: target, id: id)) { Label("Open", systemImage: "arrow.up.right") }
                }
                Button { PlatformPasteboard.copy(ValueFormat.text(value, column: column, refTitle: row.refs?[column.name])) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private func computed(_ row: DataRow) -> some View {
        let columns = (collection?.visibleColumns ?? []).filter(\.isComputed)
        if !columns.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "Computed"))
                VStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        FieldLine(column: column, value: row[column.name], refTitle: row.refs?[column.name], saving: false, editable: false)
                        if index < columns.count - 1 { Divider().overlay(Color.line).padding(.leading, 16) }
                    }
                }
                .groupCard()
            }
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let changes = showsAllHistory ? store.history : Array(store.history.prefix(5))
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "History"))
                VStack(spacing: 0) {
                    ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                        HistoryLine(change: change, summary: changeSummary(change), canRevert: change.op == .update || change.op == .revert) {
                            pendingRevert = change
                        }
                        if index < changes.count - 1 { Divider().overlay(Color.line).padding(.leading, 52) }
                    }
                    if store.history.count > 5 && !showsAllHistory {
                        Divider().overlay(Color.line)
                        Button("Show all (\(store.history.count))") { withAnimation(.snappy) { showsAllHistory = true } }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .groupCard()
            }
        }
    }

    private func changeSummary(_ change: DataChange) -> String {
        switch change.op {
        case .insert: return String(localized: "Created")
        case .archive: return String(localized: "Archived")
        case .unarchive: return String(localized: "Restored")
        case .delete: return String(localized: "Deleted")
        default: break
        }
        let parts = change.changes.keys.sorted { (collection?.column($0)?.order ?? 99) < (collection?.column($1)?.order ?? 99) }.compactMap { key -> String? in
            guard let pair = change.changes[key], pair.count == 2 else { return nil }
            let column = collection?.column(key)
            if column?.isComputed == true { return nil }
            let label = column?.label ?? key
            return "\(label): \(ValueFormat.text(pair[0], column: column)) → \(ValueFormat.text(pair[1], column: column))"
        }
        let text = parts.joined(separator: "\n")
        return change.op == .revert ? String(localized: "Reverted\n\(text)") : text
    }

    private func archiveButton(_ row: DataRow) -> some View {
        Button {
            Haptics.tap()
            confirmArchive = true
        } label: {
            Label(row.archivedAt == nil ? String(localized: "Archive") : String(localized: "Restore"), systemImage: row.archivedAt == nil ? "archivebox" : "tray.and.arrow.up")
        }
        .buttonStyle(InkButtonStyle(prominent: false, destructive: row.archivedAt == nil))
        .padding(.top, 4)
    }
}

struct FieldLine: View {
    let column: DataColumn
    let value: JSONValue
    let refTitle: String?
    let saving: Bool
    let editable: Bool

    var body: some View {
        HStack(alignment: column.type == .longtext ? .top : .center, spacing: 12) {
            HStack(spacing: 5) {
                if column.isComputed { Image(systemName: "function").font(.caption2.weight(.bold)).foregroundStyle(Color.text3) }
                Text(column.label).font(.subheadline).foregroundStyle(Color.text2)
            }
            .frame(minWidth: 96, alignment: .leading)
            Spacer(minLength: 8)
            valueView
                .frame(maxWidth: .infinity, alignment: .trailing)
            if saving {
                ProgressView().controlSize(.mini)
            } else if editable {
                Image(systemName: column.type == .ref || column.type == .file ? "chevron.right" : "pencil")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.text3.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var valueView: some View {
        switch column.type {
        case _ where (value.isNull || value.string == "") && column.type != .refs:
            Text("—").foregroundStyle(Color.text3)
        case .select:
            if let option = ValueFormat.option(value.string, in: column) { OptionChip(option: option) } else { plain }
        case .multiselect:
            HStack(spacing: 4) {
                ForEach(value.stringArray, id: \.self) { item in
                    OptionChip(option: ValueFormat.option(item, in: column) ?? DataOption(value: item), compact: true)
                }
            }
        case .money:
            Text(ValueFormat.text(value, column: column))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.ink)
        case .date, .datetime:
            VStack(alignment: .trailing, spacing: 1) {
                plain
                if let date = value.string.flatMap(ValueFormat.parseDate), ValueFormat.isNear(date) {
                    Text(ValueFormat.relativeDay(date)).font(.caption).foregroundStyle(Color.text3)
                }
            }
        case .url:
            Text(value.string.flatMap { URL(string: $0)?.host() } ?? value.string ?? "")
                .font(.subheadline).foregroundStyle(Color.accentInk).lineLimit(1)
        case .longtext:
            Text(value.string ?? "").font(.subheadline).foregroundStyle(Color.ink).multilineTextAlignment(.trailing).lineLimit(6)
        case .ref:
            Text(refTitle ?? value.string ?? "").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
        case .refs:
            Text(ValueFormat.text(value, column: column, refTitle: refTitle)).font(.subheadline).foregroundStyle(Color.ink)
                .multilineTextAlignment(.trailing).lineLimit(3)
        case .file:
            Label(ValueFormat.text(value, column: column), systemImage: "paperclip").font(.subheadline).foregroundStyle(Color.accentInk).lineLimit(1)
        default:
            plain
        }
    }

    private var plain: some View {
        Text(ValueFormat.text(value, column: column, refTitle: refTitle))
            .font(.subheadline)
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
    }
}

struct HistoryLine: View {
    let change: DataChange
    let summary: String
    let canRevert: Bool
    let onRevert: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: change.source == "app" ? "iphone" : change.source == "import" ? "square.and.arrow.down" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(change.source == "app" ? Color.text2 : Color.accentInk)
                .frame(width: 28, height: 28)
                .background(change.source == "app" ? Color.chip : Color.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(change.source == "app" ? String(localized: "You") : change.source == "import" ? String(localized: "Import") : String(localized: "Bot"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text(change.at.relativeLabel).font(.caption).foregroundStyle(Color.text3)
                }
                Text(summary).font(.footnote).foregroundStyle(Color.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if canRevert {
                Button(action: onRevert) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .frame(width: 32, height: 32)
                        .background(Color.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo this change")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}
