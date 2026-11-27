import Foundation
import Observation
import SwiftUI

/// Root of the Fichiers tab: dashboards, collections and the docs tree. Shared so every screen of the tab
/// (and the dashboards) can read the collection metadata without refetching it.
@MainActor
@Observable
final class FilesHomeStore {
    static let shared = FilesHomeStore()

    private(set) var collections: [DataCollection] = []
    private(set) var dashboards: [DashboardSummary] = []
    private(set) var docs: [DocNode] = [] {
        didSet { if docs != oldValue { index = DocsIndex(docs) } }
    }
    private(set) var index = DocsIndex()
    /// Dashboards fetched in the background for the headline figure of their card.
    private(set) var previews: [String: Dashboard] = [:]
    private(set) var loaded = false
    private(set) var error: String?
    @ObservationIgnored private(set) var api: (any NuoAPI)?
    /// When the shown data was last asked for; `loadIfStale` reuses it for a while.
    @ObservationIgnored private var fetchedAt: Date?
    /// Every visit of a Fichiers screen fetched everything again, each dashboard preview included.
    private static let freshFor: TimeInterval = 30

    func attach(_ api: any NuoAPI) { self.api = api }

    /// Screen visits: data fetched moments ago is shown as is. Pull-to-refresh and explicit refreshes call `load`.
    func loadIfStale() async {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.freshFor { return }
        await load()
    }

    /// Back in the foreground: the next visit fetches again.
    func markStale() { fetchedAt = nil }

    func load() async {
        guard let api else { return }
        restorePins()
        let cache = WorkspaceCache.shared
        if !loaded {
            if let value = await cache.value([DataCollection].self, "collections") { collections = value }
            if let value = await cache.value([DashboardSummary].self, "dashboards") { dashboards = value }
            if let value = await cache.value([DocNode].self, "docs.tree") { docs = value }
            for summary in dashboards {
                if let value = await cache.value(Dashboard.self, "dashboard.\(summary.slug)") { previews[summary.slug] = value }
            }
            loaded = !(collections.isEmpty && dashboards.isEmpty && docs.isEmpty)
        }
        fetchedAt = Date()
        async let collectionsTask = api.collections()
        async let dashboardsTask = api.dashboards()
        async let docsTask = api.docsTree()
        var failures: [String] = []
        // Runs on every visit of the Fichiers screens: unchanged answers must not re-render the cards (charts included).
        do {
            let fetched = try await collectionsTask
            if fetched != collections {
                collections = fetched
                cache.store(fetched, "collections")
            }
        } catch { failures.append(error.localizedDescription) }
        do {
            let fetched = try await dashboardsTask
            if fetched != dashboards {
                dashboards = fetched
                cache.store(fetched, "dashboards")
            }
        } catch { failures.append(error.localizedDescription) }
        do {
            let fetched = try await docsTask
            if fetched != docs {
                docs = fetched
                cache.store(fetched, "docs.tree")
            }
        } catch { failures.append(error.localizedDescription) }
        if error != failures.first { error = failures.first }
        if !loaded { loaded = true }
        if !failures.isEmpty { fetchedAt = nil }
        await syncPins()
        await refreshPreviews()
    }

    func refreshPreviews() async {
        guard let api else { return }
        await withTaskGroup(of: Dashboard?.self) { group in
            for summary in dashboards {
                group.addTask { try? await api.dashboard(slug: summary.slug) }
            }
            for await dashboard in group {
                guard let dashboard, previews[dashboard.slug] != dashboard else { continue }
                previews[dashboard.slug] = dashboard
                WorkspaceCache.shared.store(dashboard, "dashboard.\(dashboard.slug)")
            }
        }
    }

    func collection(_ id: String) -> DataCollection? { collections.first { $0.id == id } }

    func storePreview(_ dashboard: Dashboard) { previews[dashboard.slug] = dashboard }

    func refreshDocs() async {
        guard let api, let tree = try? await api.docsTree() else { return }
        docs = tree
        WorkspaceCache.shared.store(tree, "docs.tree")
    }

    // MARK: Pins

    /// Pinned files and folders, in the user's order. Kept on the device too, so they show at once and offline;
    /// local changes the gateway has not taken yet (offline, or a gateway without the pins routes) are sent again
    /// at the next sync.
    private(set) var pins: [String] = []
    @ObservationIgnored private var pinsDirty = false
    @ObservationIgnored private var pinsNamespace: String?
    @ObservationIgnored private var pinsGeneration = 0

    private struct LocalPins: Codable {
        var paths: [String]
        var dirty: Bool
    }

    private var pinsKey: String { "nuo.docs.pins." + WorkspaceCache.shared.namespace }

    /// Pins whose file or folder is in the tree.
    var pinnedNodes: [DocNode] { pins.compactMap(node) }

    func isPinned(_ path: String) -> Bool { pins.contains(path) }

    private func restorePins() {
        let namespace = WorkspaceCache.shared.namespace
        guard pinsNamespace != namespace else { return }
        pinsNamespace = namespace
        let saved = UserDefaults.standard.data(forKey: pinsKey).flatMap { try? JSONDecoder().decode(LocalPins.self, from: $0) }
        pins = saved?.paths ?? []
        pinsDirty = saved?.dirty ?? false
    }

    private func savePins() {
        guard let data = try? JSONEncoder().encode(LocalPins(paths: pins, dirty: pinsDirty)) else { return }
        UserDefaults.standard.set(data, forKey: pinsKey)
    }

    func syncPins() async {
        restorePins()
        guard let api else { return }
        let generation = pinsGeneration
        do {
            let fresh = pinsDirty ? try await api.setDocPins(pins) : try await api.docPins()
            guard generation == pinsGeneration else { return }
            pins = fresh
            pinsDirty = false
            savePins()
        } catch {
            // Offline or a gateway without the pins routes: the local pins stay and are sent again later.
        }
    }

    func setPinned(_ paths: [String], _ pinned: Bool) {
        restorePins()
        if pinned { pins += paths.filter { !pins.contains($0) } } else { pins.removeAll { paths.contains($0) } }
        pinsChanged()
    }

    func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        var visible = pinnedNodes.map(\.path)
        visible.move(fromOffsets: source, toOffset: destination)
        pins = visible + pins.filter { !visible.contains($0) }
        pinsChanged()
    }

    private func pinsChanged() {
        pinsGeneration += 1
        pinsDirty = true
        savePins()
        Task { await syncPins() }
    }

    private func updatePins(_ map: (String) -> String?) {
        restorePins()
        var seen = Set<String>()
        let updated = pins.compactMap(map).filter { seen.insert($0).inserted }
        if updated != pins {
            pins = updated
            pinsChanged()
        }
    }

    // MARK: Docs tree

    func children(of folder: String) -> [DocNode] { index.children[folder] ?? [] }

    func fileCount(in folder: String) -> Int { index.fileCounts[folder] ?? 0 }

    var recentDocs: [DocNode] { index.recent }

    func parent(of path: String) -> String { DocsIndex.parent(of: path) }

    func node(_ path: String) -> DocNode? { index.nodes[path] }

    /// Every folder, depth first, for the « Déplacer vers… » menus.
    var folders: [DocNode] {
        func walk(_ folder: String) -> [DocNode] {
            children(of: folder).filter { $0.kind == .dir }.flatMap { [$0] + walk($0.path) }
        }
        return walk("")
    }

    /// Whether `folder` can take at least one of `paths` and none of them is the folder itself or one of its parents.
    func canMove(_ paths: [String], into folder: String) -> Bool {
        let roots = Self.roots(paths)
        guard !roots.isEmpty else { return false }
        if roots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { return false }
        return roots.contains { parent(of: $0) != folder }
    }

    /// Paths without those already inside another one of the list (moving a folder moves its content).
    static func roots(_ paths: [String]) -> [String] {
        let unique = Set(paths)
        return unique.filter { path in !unique.contains { path.hasPrefix($0 + "/") } }.sorted()
    }

    /// Where `path` is after `moves` (old path → new path), when it or one of its folders moved.
    static func path(_ path: String, after moves: [String: String]) -> String? {
        if let moved = moves[path] { return moved }
        for (from, to) in moves where path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
        return nil
    }

    // MARK: Docs operations

    struct DocsFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Moves files and folders into `folder` ("" is the top level). Returns the new path of each moved item and
    /// one message per failure.
    func move(_ paths: [String], into folder: String) async -> (moves: [String: String], failures: [String]) {
        guard let api else { return ([:], [String(localized: "Offline")]) }
        var moves: [String: String] = [:]
        var failures: [String] = []
        let roots = Self.roots(paths)
        // Open documents are saved first and kept from saving during the move, then follow it.
        let held = await DocSessions.shared.hold(under: roots)
        defer { DocSessions.shared.resume(held, after: moves) }
        for path in roots where parent(of: path) != folder {
            let name = (path as NSString).lastPathComponent
            let label = DocNames.display(name: name)
            if folder == path || folder.hasPrefix(path + "/") {
                failures.append(String(localized: "“\(label)” cannot go into itself."))
                continue
            }
            let target = folder.isEmpty ? name : folder + "/" + name
            if node(target) != nil {
                failures.append(Self.exists(label, in: folder))
                continue
            }
            do {
                moves[path] = try await api.moveDoc(from: path, to: target).path
            } catch {
                failures.append(Self.message(error, label: label, folder: folder))
            }
        }
        if !moves.isEmpty { updatePins { Self.path($0, after: moves) ?? $0 } }
        await refreshDocs()
        return (moves, failures)
    }

    /// Renames a file or a folder in place; returns its new path.
    func rename(_ path: String, to input: String) async throws -> String {
        guard let api else { throw NuoError.offline }
        let name = (path as NSString).lastPathComponent
        let isFolder = node(path)?.kind == .dir
        guard input.trimmingCharacters(in: .whitespaces) != DocNames.display(name: name) else { return path }
        guard let newName = DocNames.fileName(from: input, original: isFolder ? nil : name, isFolder: isFolder) else {
            throw DocsFailure(message: String(localized: "The name cannot be empty."))
        }
        guard newName != name else { return path }
        let folder = parent(of: path)
        let target = folder.isEmpty ? newName : folder + "/" + newName
        if node(target) != nil, target.lowercased() != path.lowercased() {
            throw DocsFailure(message: Self.exists(DocNames.display(name: newName), in: folder))
        }
        let held = await DocSessions.shared.hold(under: [path])
        var moves: [String: String] = [:]
        defer { DocSessions.shared.resume(held, after: moves) }
        do {
            let moved = try await api.moveDoc(from: path, to: target).path
            moves[path] = moved
            updatePins { Self.path($0, after: [path: moved]) ?? $0 }
            await refreshDocs()
            return moved
        } catch {
            throw DocsFailure(message: Self.message(error, label: DocNames.display(name: newName), folder: folder))
        }
    }

    /// Creates a folder named from `input` inside `parentFolder`; returns its path.
    func createFolder(named input: String, in parentFolder: String) async throws -> String {
        guard let api else { throw NuoError.offline }
        guard let name = DocNames.fileName(from: input, isFolder: true) else { throw DocsFailure(message: String(localized: "The name cannot be empty.")) }
        let path = parentFolder.isEmpty ? name : parentFolder + "/" + name
        if node(path) != nil { throw DocsFailure(message: Self.exists(DocNames.display(name: name), in: parentFolder)) }
        do {
            try await api.createDocFolder(path: path)
        } catch {
            throw DocsFailure(message: Self.message(error, label: DocNames.display(name: name), folder: parentFolder))
        }
        await refreshDocs()
        return path
    }

    /// Documents and folders (with everything inside) go to the docs trash; returns one message per failure.
    func delete(_ paths: [String]) async -> [String] {
        guard let api else { return [String(localized: "Offline")] }
        var failures: [String] = []
        for path in Self.roots(paths) {
            let held = await DocSessions.shared.hold(under: [path])
            do {
                if node(path)?.kind == .dir { try await api.deleteDocFolder(path: path) } else { try await api.deleteDoc(path: path) }
                updatePins { $0 == path || $0.hasPrefix(path + "/") ? nil : $0 }
                DocSessions.shared.discard(held)
            } catch {
                DocSessions.shared.resume(held, after: [:])
                failures.append("\(DocNames.display(name: (path as NSString).lastPathComponent)): \(error.localizedDescription)")
            }
        }
        await refreshDocs()
        return failures
    }

    private static func exists(_ label: String, in folder: String) -> String {
        String(localized: "An item named “\(label)” already exists in “\(DocNames.folderName(folder))”.")
    }

    private static func message(_ error: Error, label: String, folder: String) -> String {
        if let error = error as? NuoError, error.isConflict { return exists(label, in: folder) }
        return "\(label): \(error.localizedDescription)"
    }
}

/// Rows of one collection with search, sort, filters and cursor pagination.
@MainActor
@Observable
final class CollectionStore {
    let collectionId: String
    private(set) var rows: [DataRow] = [] {
        didSet { reindex() }
    }
    /// Every appearing row asks for its position; a linear search there made scrolling long collections stutter.
    @ObservationIgnored private var rowIndex: [String: Int] = [:]
    private(set) var total: Int?
    private(set) var nextCursor: String?
    private(set) var loaded = false
    private(set) var loadingMore = false
    private(set) var error: String?
    /// The next page failed: paging stops until `loadMore` is asked again, instead of retrying at every row shown.
    private(set) var pageError: String?
    var query = DataQuery()
    /// The gateway's `by` while the collection shows groups instead of rows.
    var groupBy: String?
    private(set) var groups: DataGroups?
    /// The group the rows were narrowed to, shown as a removable chip.
    private(set) var drilled: (column: String, label: String)?
    @ObservationIgnored private var api: (any NuoAPI)?
    @ObservationIgnored private var generation = 0
    /// Cell edits of a row run one after the other, so the gateway applies them in the order they were made.
    @ObservationIgnored private var rowUpdates: [String: Task<String?, Never>] = [:]
    @ObservationIgnored private var rowUpdateCount: [String: Int] = [:]
    static let pageSize = 50
    #if os(macOS)
    /// Fewer, larger pages: fewer round trips while scrolling a long collection (gateway max 200).
    static let nextPageSize = 200
    #else
    static let nextPageSize = 50
    #endif

    init(collectionId: String) {
        self.collectionId = collectionId
        if let cached = WorkspaceCache.shared.memoryValue(DataRowsPage.self, Self.key(collectionId, DataQuery())) {
            rows = cached.rows
            total = cached.total
            nextCursor = cached.nextCursor
            loaded = true
        }
        reindex()
    }

    private func reindex() {
        rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func key(_ id: String, _ query: DataQuery) -> String { "rows.\(id).\(query.cacheKey)" }

    func attach(_ api: any NuoAPI) { self.api = api }

    func reload() async {
        guard let api else { return }
        generation += 1
        let current = generation
        let query = self.query
        if let by = groupBy {
            do {
                let groups = try await api.groups(collection: collectionId, by: by, query: query)
                guard current == generation else { return }
                withAnimation(.snappy(duration: 0.2)) { self.groups = groups }
                error = nil
            } catch {
                guard current == generation else { return }
                self.error = error.localizedDescription
            }
            loaded = true
            return
        }
        groups = nil
        pageError = nil
        let key = Self.key(collectionId, query)
        if !loaded || rows.isEmpty, let cached = await WorkspaceCache.shared.value(DataRowsPage.self, key) {
            guard current == generation else { return }
            rows = cached.rows
            total = cached.total
            nextCursor = cached.nextCursor
            loaded = true
        }
        do {
            let page = try await api.rows(collection: collectionId, query: query, limit: Self.pageSize, cursor: nil)
            guard current == generation else { return }
            withAnimation(.snappy(duration: 0.2)) {
                rows = page.rows
                total = page.total
                nextCursor = page.nextCursor
            }
            loaded = true
            error = nil
            // Only the unfiltered first page goes to disk; filtered pages stay in memory.
            WorkspaceCache.shared.store(page, key, persist: query == DataQuery())
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }

    /// Called as rows appear; fetches the next page well before the end of the list.
    func rowAppeared(_ row: DataRow) {
        guard pageError == nil, let index = rowIndex[row.id], index >= rows.count - 15 else { return }
        loadMore()
    }

    func loadMore() {
        guard let cursor = nextCursor, !loadingMore, let api else { return }
        loadingMore = true
        pageError = nil
        let current = generation
        let query = self.query
        Task {
            defer { loadingMore = false }
            do {
                let page = try await api.rows(collection: collectionId, query: query, limit: Self.nextPageSize, cursor: cursor)
                guard current == generation else { return }
                rows += page.rows.filter { rowIndex[$0.id] == nil }
                nextCursor = page.nextCursor
                total = page.total ?? total
            } catch {
                guard current == generation else { return }
                pageError = error.localizedDescription
            }
        }
    }

    /// Edits one cell: the grid shows the new value at once, the edits of a row reach the gateway in order and only
    /// the answer to the latest one is shown. Returns the error message when the edit failed.
    func update(_ rowId: String, _ column: String, _ value: JSONValue) async -> String? {
        guard let api else { return NuoError.offline.localizedDescription }
        if let index = rowIndex[rowId] { rows[index].values[column] = value }
        let previous = rowUpdates[rowId]
        let number = (rowUpdateCount[rowId] ?? 0) + 1
        rowUpdateCount[rowId] = number
        let collectionId = collectionId
        let task = Task { () -> String? in
            _ = await previous?.value
            do {
                let updated = try await api.updateRow(collection: collectionId, id: rowId, values: [column: value])
                if rowUpdateCount[rowId] == number { replace(updated) }
                return nil
            } catch {
                if rowUpdateCount[rowId] == number {
                    // The value shown is not the gateway's: show its version again.
                    if let detail = try? await api.row(collection: collectionId, id: rowId) { replace(detail.row) }
                }
                return error.localizedDescription
            }
        }
        rowUpdates[rowId] = task
        let failure = await task.value
        if rowUpdateCount[rowId] == number {
            rowUpdates[rowId] = nil
            rowUpdateCount[rowId] = nil
        }
        return failure
    }

    func row(_ id: DataRow.ID) -> DataRow? { rowIndex[id].map { rows[$0] } }

    /// Leaves the groups for the rows of one of them.
    func open(_ group: DataGroup, of grouping: DataGrouping) {
        query.filters.removeAll { $0.column == grouping.column.name }
        query.filters += grouping.filters(group)
        drilled = (grouping.column.name, grouping.label(group))
        groupBy = nil
        rows = []
        loaded = false
    }

    func closeDrilledGroup() {
        guard let drilled else { return }
        query.filters.removeAll { $0.column == drilled.column }
        self.drilled = nil
    }

    func clearFilters() {
        query.filters = []
        drilled = nil
    }

    func replace(_ row: DataRow) {
        if let index = rowIndex[row.id] {
            if row.archivedAt != nil {
                rows.remove(at: index)
                total = total.map { $0 - 1 }
            } else {
                rows[index] = row
            }
        }
    }
}

/// One row, its history, and edits.
@MainActor
@Observable
final class RowStore {
    let collectionId: String
    let rowId: String
    private(set) var row: DataRow?
    private(set) var history: [DataChange] = []
    /// Loading failed.
    private(set) var error: String?
    /// An edit, archive, revert or attachment failed; cleared once shown.
    var failure: String?
    private(set) var saving: Set<String> = []
    @ObservationIgnored private var api: (any NuoAPI)?

    init(collectionId: String, rowId: String, seed: DataRow?) {
        self.collectionId = collectionId
        self.rowId = rowId
        if let cached = WorkspaceCache.shared.memoryValue(DataRowDetail.self, Self.key(collectionId, rowId)) {
            row = cached.row
            history = cached.history
        } else {
            row = seed
        }
    }

    private static func key(_ collection: String, _ row: String) -> String { "row.\(collection).\(row)" }

    func attach(_ api: any NuoAPI) { self.api = api }

    /// The row as edited elsewhere (the grid): shown unless an edit of this screen is on its way.
    func adopt(_ fresh: DataRow) {
        guard saving.isEmpty, fresh.id == rowId, fresh != row else { return }
        row = fresh
    }

    func load() async {
        guard let api else { return }
        do {
            let detail = try await api.row(collection: collectionId, id: rowId)
            withAnimation(.snappy(duration: 0.2)) {
                row = detail.row
                history = detail.history
            }
            error = nil
            WorkspaceCache.shared.store(detail, Self.key(collectionId, rowId), persist: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func update(_ column: String, _ value: JSONValue) async -> Bool {
        guard let api, var current = row else { return false }
        let previous = current
        current.values[column] = value
        row = current
        saving.insert(column)
        defer { saving.remove(column) }
        do {
            row = try await api.updateRow(collection: collectionId, id: rowId, values: [column: value])
            Haptics.success()
            await load()
            return true
        } catch {
            row = previous
            failure = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func attach(_ column: String, name: String, data: Data, contentType: String) async -> Bool {
        guard let api else { return false }
        saving.insert(column)
        defer { saving.remove(column) }
        do {
            row = try await api.attachFile(collection: collectionId, id: rowId, column: column, name: name, data: data, contentType: contentType)
            Haptics.success()
            await load()
            return true
        } catch {
            failure = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func setArchived(_ archived: Bool) async -> Bool {
        guard let api else { return false }
        do {
            row = try await api.archiveRow(collection: collectionId, id: rowId, archived: archived)
            Haptics.success()
            return true
        } catch {
            failure = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func revert(_ change: DataChange) async {
        guard let api else { return }
        do {
            _ = try await api.revertChange(id: change.id)
            Haptics.success()
            await load()
        } catch {
            failure = error.localizedDescription
            Haptics.error()
        }
    }
}

@MainActor
@Observable
final class DashboardStore {
    let slug: String
    private(set) var dashboard: Dashboard?
    private(set) var error: String?
    private(set) var loading = false
    @ObservationIgnored private var api: (any NuoAPI)?

    init(slug: String) {
        self.slug = slug
        dashboard = FilesHomeStore.shared.previews[slug]
    }

    func attach(_ api: any NuoAPI) { self.api = api }

    func load() async {
        guard let api else { return }
        if dashboard == nil { dashboard = await WorkspaceCache.shared.value(Dashboard.self, "dashboard.\(slug)") }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await api.dashboard(slug: slug)
            withAnimation(.snappy(duration: 0.25)) { dashboard = fresh }
            error = nil
            WorkspaceCache.shared.store(fresh, "dashboard.\(slug)")
            FilesHomeStore.shared.storePreview(fresh)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class DocStore {
    /// `retryable`: the gateway could not be reached or failed on its side; trying again later may work.
    enum SaveOutcome { case saved(DocFile), conflict, failed(String, retryable: Bool) }
    enum Latest { case file(DocFile), missing, failed(String, retryable: Bool) }

    private(set) var path: String
    private(set) var file: DocFile?
    private(set) var error: String?
    @ObservationIgnored private var api: (any NuoAPI)?
    /// Bumped by each save: a fetch that started before it may bring back the version it replaced.
    @ObservationIgnored private var saves = 0

    init(path: String) {
        self.path = path
        file = WorkspaceCache.shared.memoryValue(DocFile.self, Self.key(path))
    }

    private static func key(_ path: String) -> String { "doc.\(path)" }

    func attach(_ api: any NuoAPI) { self.api = api }

    /// The document was moved or renamed: the same content now lives at `newPath`.
    func moved(to newPath: String) {
        guard newPath != path else { return }
        path = newPath
        if var file {
            file.path = newPath
            self.file = file
            WorkspaceCache.shared.store(file, Self.key(newPath))
        }
    }

    func load() async {
        guard let api else { return }
        if file == nil { file = await WorkspaceCache.shared.value(DocFile.self, Self.key(path)) }
        let path = path, saves = saves
        do {
            let fresh = try await api.doc(path: path)
            guard saves == self.saves, path == self.path else { return }
            if fresh != file { withAnimation(.easeOut(duration: 0.15)) { file = fresh } }
            error = nil
            WorkspaceCache.shared.store(fresh, Self.key(path))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// `baseSha` is the version the edits started from; nil overwrites whatever is on the gateway.
    func save(_ content: String, baseSha: String?) async -> SaveOutcome {
        guard let api else { return .failed(String(localized: "Offline"), retryable: true) }
        saves += 1
        let path = path
        do {
            let result = try await api.saveDoc(path: path, content: content, baseSha: baseSha)
            let saved = DocFile(path: path, content: content, sha: result.sha, updatedAt: result.updatedAt ?? Date())
            if path == self.path {
                file = saved
                WorkspaceCache.shared.store(saved, Self.key(path))
            }
            Haptics.success()
            return .saved(saved)
        } catch let error as NuoError where error.isConflict {
            Haptics.error()
            return .conflict
        } catch {
            Haptics.error()
            return .failed(error.localizedDescription, retryable: Self.isTransient(error))
        }
    }

    /// Network trouble and gateway-side failures; a refused request (4xx) fails the same way next time.
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? NuoError else { return true }
        switch error {
        case .offline, .transport: return true
        case let .server(status, _): return status >= 500 || status == 408 || status == 429
        default: return false
        }
    }

    /// Puts an attachment in `<doc folder>/_fichiers/`; returns its path relative to the document, as Markdown links it.
    func upload(name: String, data: Data, contentType: String) async throws -> (src: String, name: String, size: Int) {
        guard let api else { throw NuoError.offline }
        guard data.count <= DocAttachments.maxBytes else { throw DocAttachments.Failure.tooLarge(name) }
        let folder = (path as NSString).deletingLastPathComponent
        let target = (folder.isEmpty ? "" : folder + "/") + DocAttachments.folder + "/" + DocAttachments.safeName(name)
        do {
            let result = try await api.uploadDocFile(path: target, data: data, contentType: contentType)
            let relative = folder.isEmpty ? result.path : String(result.path.dropFirst(folder.count + 1))
            return (relative, (result.path as NSString).lastPathComponent, result.size)
        } catch NuoError.notFound {
            throw DocAttachments.Failure.unsupported
        } catch let NuoError.server(status, _) where status == 413 {
            throw DocAttachments.Failure.tooLarge(name)
        }
    }

    /// Latest version from the gateway, for the conflict screen.
    func fetchLatest() async -> Latest {
        guard let api else { return .failed(String(localized: "Offline"), retryable: true) }
        do {
            return .file(try await api.doc(path: path))
        } catch NuoError.notFound {
            return .missing
        } catch let NuoError.server(status, _) where status == 404 {
            return .missing
        } catch {
            return .failed(error.localizedDescription, retryable: Self.isTransient(error))
        }
    }

    func adopt(_ latest: DocFile) {
        file = latest
        WorkspaceCache.shared.store(latest, Self.key(path))
    }
}

enum DocAttachments {
    static let folder = "_fichiers"
    static let maxBytes = 50 * 1024 * 1024

    enum Failure: LocalizedError {
        case unsupported, tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Your gateway cannot receive files for documents yet. Update it, then try again.")
            case let .tooLarge(name): String(localized: "“\(name)” is over 50 MB.")
            }
        }
    }

    /// "Photo de vacances (1).JPG" → "Photo-de-vacances-1.JPG": readable in Markdown links without escaping.
    static func safeName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension.folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if stem.isEmpty { stem = "fichier" }
        return ext.isEmpty ? stem : "\(stem).\(ext.lowercased())"
    }
}
