import SwiftUI

struct DashboardList: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var home = FilesHomeStore.shared
    @State private var lastTick: Int?

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.dashboard) {
            if !home.loaded { SkeletonRows(count: 4) }
            ForEach(home.dashboards) { summary in
                DashboardListRow(summary: summary, preview: home.previews[summary.slug])
                    .tag(summary.slug)
            }
        }
        .overlay {
            if home.loaded && home.dashboards.isEmpty, home.error == nil {
                ContentUnavailableView("No dashboard", systemImage: "chart.bar.xaxis",
                                       description: Text("Ask a bot to create one in dashboards/."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { HomeErrorBanner(home: home) }
        .task(id: navigator.refreshTick) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            home.markStale()
            Task { await home.load() }
        }
    }

    private func reload() async {
        home.attach(session.api)
        // A new tick is an explicit refresh; the first run of the list reuses data fetched moments ago.
        let refresh = lastTick.map { $0 != navigator.refreshTick } ?? false
        lastTick = navigator.refreshTick
        if refresh { await home.load() } else { await home.loadIfStale() }
        if navigator.dashboard == nil { navigator.dashboard = home.dashboards.first?.slug }
    }
}

private struct DashboardListRow: View {
    let summary: DashboardSummary
    let preview: Dashboard?

    private var figure: DashboardBlock? { preview?.blocks.first { $0.type == .number } }

    var body: some View {
        HStack(spacing: 10) {
            EmojiTile(emoji: summary.emoji ?? "📊", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body.weight(.medium)).lineLimit(1)
                if let figure, let value = figure.value {
                    Text("\(figure.title) · \(ValueFormat.formatted(value, format: figure.format))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let description = summary.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct CollectionList: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var home = FilesHomeStore.shared
    @State private var lastTick: Int?

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.collection) {
            if !home.loaded { SkeletonRows(count: 5) }
            ForEach(home.collections) { collection in
                HStack(spacing: 10) {
                    EmojiTile(emoji: collection.emoji ?? "🗂️", size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(collection.label).font(.body.weight(.medium)).lineLimit(1)
                        Text(verbatim: "\(String(localized: "\(collection.count) items")) · \(String(localized: "\(collection.visibleColumns.count) columns"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(collection.id)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { HomeErrorBanner(home: home) }
        .task(id: navigator.refreshTick) {
            home.attach(session.api)
            let refresh = lastTick.map { $0 != navigator.refreshTick } ?? false
            lastTick = navigator.refreshTick
            if refresh { await home.load() } else { await home.loadIfStale() }
            if navigator.collection == nil { navigator.collection = home.collections.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            home.markStale()
            Task { await home.load() }
        }
    }
}

/// Docs repository as a Finder-like outline: folders expand, can be selected, renamed, moved and deleted, and take
/// drops of documents and folders dragged from the tree. Search runs on the gateway (`GET /api/docs/search`).
struct DocsTree: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @State private var home = FilesHomeStore.shared
    @State private var outline = DocsOutline()
    @State private var search = ""
    @State private var hits: [DocSearchHit] = []
    @State private var searchError: String?
    @State private var lastTick: Int?
    @State private var sessions = DocSessions.shared
    @State private var prompt: DocsNamePrompt?
    @State private var promptText = ""
    @State private var pendingDelete: [String] = []
    @State private var failure: DocsAlert?
    @FocusState private var searchFocused: Bool

    /// `body` is split in three: as one chain, the modifiers take the type checker past its time limit on slower machines.
    private var outlineList: some View {
        // A closure, not `select` itself: Swift 6.3 crashes emitting the thunk that converts the method for Binding.
        List(selection: Binding(get: { outline.selection }, set: { select($0) })) {
            if !search.isEmpty {
                Section("Results") {
                    ForEach(hits) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DocNames.display(name: (hit.path as NSString).lastPathComponent)).font(.body.weight(.medium))
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .tag(hit.path)
                    }
                    if let searchError {
                        Label("Search failed: \(searchError)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if hits.isEmpty {
                        Text("No results").foregroundStyle(.secondary)
                    }
                }
            } else {
                if !sessions.needingAttention.isEmpty {
                    Section(String(localized: "files.unsaved.section", defaultValue: "Not saved")) {
                        ForEach(sessions.needingAttention, id: \.path) { unsaved in
                            Label(DocNames.display(name: (unsaved.path as NSString).lastPathComponent), systemImage: "exclamationmark.triangle")
                                .help(unsaved.status == .conflict ? String(localized: "Changed elsewhere while you were writing: open it to choose the version to keep.")
                                    : String(localized: "Saving failed; trying again in a few seconds."))
                                .padding(.vertical, 3)
                                .tag(DocsOutline.unsavedPrefix + unsaved.path)
                        }
                    }
                }
                if !home.pinnedNodes.isEmpty {
                    Section("Pinned") {
                        ForEach(home.pinnedNodes) { node in
                            Label(DocNames.display(node), systemImage: node.kind == .dir ? "folder" : "doc.text")
                                .padding(.vertical, 3)
                                .tag(DocsOutline.pinnedPrefix + node.path)
                        }
                        .onMove { home.movePins(fromOffsets: $0, toOffset: $1) }
                    }
                }
                Section("Recent") {
                    ForEach(home.recentDocs.prefix(5)) { node in
                        Label(DocNames.display(node), systemImage: "clock")
                            .padding(.vertical, 3)
                            .tag(DocsOutline.recentPrefix + node.path)
                    }
                }
                Section {
                    DocsOutlineRows(folder: "", home: home, outline: outline, drop: drop)
                } header: {
                    Text("All documents")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .background(DocsDropHighlight(on: outline.dropTarget == ""))
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: "")
                        } isTargeted: { outline.hover(DocsOutline.rootRow, target: "", $0) }
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .searchable(text: $search, prompt: "Search docs")
        .searchFocused($searchFocused)
        .onChange(of: navigator.searchFocus) { _, _ in searchFocused = true }
        .task(id: search) {
            let query = search.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else {
                hits = []
                searchError = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                hits = try await session.api.searchDocs(query)
                searchError = nil
            } catch is CancellationError {
            } catch {
                hits = []
                searchError = error.localizedDescription
            }
        }
    }

    private var commands: some View {
        outlineList
        .safeAreaInset(edge: .top, spacing: 0) { HomeErrorBanner(home: home) }
        .toolbar {
            ToolbarItemGroup {
                Button { ask(.newFolder(parent: currentFolder)) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    .help("New folder")
                Button { ask(.newDocument(folder: currentFolder)) } label: { Label("New document", systemImage: "square.and.pencil") }
                    .help("New document")
            }
        }
        .contextMenu(forSelectionType: String.self) { tags in
            menu(for: DocsOutline.paths(tags))
        } primaryAction: { tags in
            let paths = DocsOutline.paths(tags)
            if paths.count == 1, let path = paths.first, home.node(path)?.kind == .dir { outline.toggle(path) }
        }
        .onDeleteCommand { askDelete(outline.selectedPaths) }
        .onKeyPress(.return) {
            let paths = outline.selectedPaths
            guard search.isEmpty, paths.count == 1, let path = paths.first, home.node(path) != nil else { return .ignored }
            ask(.rename(path: path))
            return .handled
        }
        .onAppear { RichDocEditor.prewarm() }
        .onChange(of: navigator.doc, initial: true) { _, doc in
            guard let doc else { return }
            outline.reveal(doc)
            if !outline.selectedPaths.contains(doc) { outline.selection = [doc] }
        }
        .onChange(of: navigator.revealFolder, initial: true) { _, folder in
            guard let folder else { return }
            outline.reveal(folder, including: true)
            outline.selection = [folder]
            navigator.revealFolder = nil
        }
    }

    var body: some View {
        commands
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let paths = pendingDelete
                Task { await delete(paths) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }), presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in Text(failure.message) }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
            TextField("Name", text: $promptText)
            Button(prompt.action) { Task { await submit(prompt, promptText) } }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: navigator.refreshTick) {
            home.attach(session.api)
            // A new tick is an explicit refresh; showing the tree again reuses data fetched moments ago.
            let refresh = lastTick.map { $0 != navigator.refreshTick } ?? false
            lastTick = navigator.refreshTick
            if refresh { await home.load() } else { await home.loadIfStale() }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for paths: [String]) -> some View {
        let single = paths.count == 1 ? paths.first.flatMap(home.node) : nil
        if paths.isEmpty {
            Button("New Document") { ask(.newDocument(folder: "")) }
            Button("New Folder") { ask(.newFolder(parent: "")) }
        } else {
            if let single, single.kind == .file {
                Button("Open in New Window") { openWindow(id: MacWindow.doc, value: single.path) }
                Divider()
            }
            let pinned = paths.allSatisfy(home.isPinned)
            Button(pinned ? String(localized: "Unpin") : String(localized: "Pin")) { home.setPinned(paths, !pinned) }
            Divider()
            if let single {
                let folder = single.kind == .dir ? single.path : home.parent(of: single.path)
                Button("New Document") { ask(.newDocument(folder: folder)) }
                Button("New Folder") { ask(.newFolder(parent: folder)) }
                Divider()
                Button("Rename…") { ask(.rename(path: single.path)) }
            }
            Menu("Move to…") {
                Button("All Documents") { Task { await move(paths, into: "") } }
                    .disabled(!home.canMove(paths, into: ""))
                Divider()
                ForEach(home.folders) { folder in
                    Button(String(repeating: "    ", count: folder.path.split(separator: "/").count - 1) + DocNames.display(folder)) {
                        Task { await move(paths, into: folder.path) }
                    }
                    .disabled(!home.canMove(paths, into: folder.path))
                }
            }
            Divider()
            Button(paths.count > 1 ? String(localized: "Delete \(paths.count) Items…") : String(localized: "Delete…"), role: .destructive) { askDelete(paths) }
        }
    }

    /// New items go into the selected folder, next to the selected document, or next to the open one.
    private var currentFolder: String {
        let paths = outline.selectedPaths
        if paths.count == 1, let path = paths.first, let node = home.node(path) {
            return node.kind == .dir ? path : home.parent(of: path)
        }
        return navigator.doc.map(home.parent(of:)) ?? ""
    }

    private func select(_ tags: Set<String>) {
        outline.selection = tags
        guard tags.count == 1, let tag = tags.first else { return }
        let path = DocsOutline.path(of: tag)
        // Selecting a folder only selects it, as in the Finder; documents open in the detail pane.
        if home.node(path)?.kind != .dir {
            navigator.doc = path
        } else if tag.hasPrefix(DocsOutline.pinnedPrefix) {
            outline.reveal(path, including: true)
        }
    }

    private func ask(_ request: DocsNamePrompt) {
        if case let .rename(path) = request {
            promptText = DocNames.display(name: (path as NSString).lastPathComponent)
        } else {
            promptText = ""
        }
        prompt = request
    }

    private func askDelete(_ paths: [String]) {
        let roots = FilesHomeStore.roots(paths).filter { home.node($0) != nil }
        if !roots.isEmpty { pendingDelete = roots }
    }

    // MARK: Operations

    private func drop(_ items: [String], into folder: String) -> Bool {
        let paths = DocsDrag.paths(items)
        guard home.canMove(paths, into: folder) else { return false }
        Task { await move(paths, into: folder) }
        return true
    }

    private func move(_ paths: [String], into folder: String) async {
        let result = await home.move(paths, into: folder)
        if !result.moves.isEmpty {
            outline.reveal(folder, including: true)
            outline.selection = Set(result.moves.values)
            follow(result.moves)
        }
        if !result.failures.isEmpty { failure = DocsAlert(title: String(localized: "Couldn't move"), message: result.failures.joined(separator: "\n")) }
    }

    /// The open document keeps showing after it (or one of its folders) moved.
    private func follow(_ moves: [String: String]) {
        if let doc = navigator.doc, let moved = FilesHomeStore.path(doc, after: moves) { navigator.doc = moved }
    }

    private func submit(_ request: DocsNamePrompt, _ text: String) async {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            switch request {
            case let .newDocument(folder):
                let slug = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let file = (folder.isEmpty ? "" : folder + "/") + (slug.isEmpty ? "note" : slug) + ".md"
                if home.node(file) != nil { throw FilesHomeStore.DocsFailure(message: String(localized: "A document named “\(name)” already exists in “\(DocNames.folderName(folder))”.")) }
                _ = try await session.api.createDoc(path: file, content: "# \(name)\n\n")
                await home.refreshDocs()
                outline.reveal(file)
                navigator.doc = file
            case let .newFolder(parent):
                let path = try await home.createFolder(named: name, in: parent)
                outline.reveal(path)
                outline.selection = [path]
            case let .rename(path):
                let renamed = try await home.rename(path, to: name)
                guard renamed != path else { return }
                outline.renamed(path, to: renamed)
                outline.selection = [renamed]
                follow([path: renamed])
            }
        } catch {
            failure = DocsAlert(title: request.failureTitle, message: error.localizedDescription)
        }
    }

    private func delete(_ paths: [String]) async {
        let failures = await home.delete(paths)
        if let doc = navigator.doc, paths.contains(where: { doc == $0 || doc.hasPrefix($0 + "/") }), home.node(doc) == nil { navigator.doc = nil }
        outline.selection = outline.selection.filter { home.node(DocsOutline.path(of: $0)) != nil }
        if !failures.isEmpty { failure = DocsAlert(title: String(localized: "Couldn't delete"), message: failures.joined(separator: "\n")) }
    }

    private var deleteTitle: String {
        guard pendingDelete.count == 1, let path = pendingDelete.first else { return String(localized: "Delete \(pendingDelete.count) items?") }
        return String(localized: "Delete “\(DocNames.display(name: (path as NSString).lastPathComponent))”?")
    }

    private var deleteMessage: String {
        let documents = pendingDelete.reduce(0) { total, path in
            total + (home.node(path)?.kind == .dir ? home.fileCount(in: path) : 1)
        }
        let folders = pendingDelete.filter { home.node($0)?.kind == .dir }
        let count = String(localized: "\(documents) documents")
        if folders.count == 1, pendingDelete.count == 1 {
            return documents == 0 ? String(localized: "The folder is empty. It goes to your documents' trash.")
                : String(localized: "The folder contains \(count). Everything goes to your documents' trash; the history keeps their content.")
        }
        if !folders.isEmpty {
            return String(localized: "\(count) in total, folders included. Everything goes to your documents' trash; the history keeps their content.")
        }
        return pendingDelete.count > 1 ? String(localized: "They go to your documents' trash; the history keeps their content.")
            : String(localized: "It goes to your documents' trash; the history keeps its content.")
    }
}

private enum DocsNamePrompt {
    case newDocument(folder: String)
    case newFolder(parent: String)
    case rename(path: String)

    var title: String {
        switch self {
        case .newDocument: String(localized: "New document")
        case .newFolder: String(localized: "New folder")
        case .rename: String(localized: "Rename")
        }
    }

    var action: String {
        if case .rename = self { return String(localized: "Rename") }
        return String(localized: "Create")
    }

    var failureTitle: String {
        if case .rename = self { return String(localized: "Couldn't rename") }
        return String(localized: "Couldn't create")
    }
}

private struct DocsAlert {
    let title: String
    let message: String
}

/// Expanded folders, selection and the folder under a drag, shared by the rows of the outline.
@MainActor
@Observable
private final class DocsOutline {
    static let recentPrefix = "recent:"
    static let pinnedPrefix = "pinned:"
    static let unsavedPrefix = "unsaved:"
    static let rootRow = "#root"

    var selection: Set<String> = []
    var expanded: Set<String> = []
    /// Row under the drag and the folder it drops into ("" is the top level).
    private(set) var hovered: String?
    private(set) var dropTarget: String?
    @ObservationIgnored private var springTask: Task<Void, Never>?

    var selectedPaths: [String] { Self.paths(selection) }

    static func path(of tag: String) -> String {
        for prefix in [recentPrefix, pinnedPrefix, unsavedPrefix] where tag.hasPrefix(prefix) { return String(tag.dropFirst(prefix.count)) }
        return tag
    }
    static func paths(_ tags: some Collection<String>) -> [String] { Set(tags.map(path(of:))).sorted() }

    func isExpanded(_ folder: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(folder) }, set: { open in
            if open { self.expanded.insert(folder) } else { self.expanded.remove(folder) }
        })
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) }
    }

    /// Expands the folders above `path` (and `path` itself when `including`).
    func reveal(_ path: String, including: Bool = false) {
        var parts = path.split(separator: "/").map(String.init)
        if !including { parts = Array(parts.dropLast()) }
        for index in parts.indices { expanded.insert(parts[...index].joined(separator: "/")) }
    }

    func renamed(_ old: String, to new: String) {
        expanded = Set(expanded.map { FilesHomeStore.path($0, after: [old: new]) ?? $0 })
    }

    /// A folder hovered by a drag springs open after a moment, as in the Finder.
    func hover(_ row: String, target: String, _ isOn: Bool) {
        if isOn {
            hovered = row
            dropTarget = target
            springTask?.cancel()
            guard row == target, !expanded.contains(row) else { return }
            springTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self, self.hovered == row else { return }
                self.expanded.insert(row)
            }
        } else if hovered == row {
            hovered = nil
            dropTarget = nil
            springTask?.cancel()
        }
    }
}

/// Paths dragged inside the tree travel as one string with a marker, so text dragged from elsewhere is ignored.
private enum DocsDrag {
    static let marker = "nuo-docs"

    static func payload(_ path: String, selection: [String]) -> String {
        let paths = selection.contains(path) ? selection : [path]
        return ([marker] + paths).joined(separator: "\n")
    }

    static func paths(_ items: [String]) -> [String] {
        items.flatMap { item -> [String] in
            let lines = item.split(separator: "\n").map(String.init)
            guard lines.first == marker else { return [] }
            return Array(lines.dropFirst())
        }
    }
}

private struct DocsOutlineRows: View {
    let folder: String
    let home: FilesHomeStore
    let outline: DocsOutline
    let drop: ([String], String) -> Bool

    var body: some View {
        ForEach(home.children(of: folder)) { node in
            if node.kind == .dir {
                DisclosureGroup(isExpanded: outline.isExpanded(node.path)) {
                    DocsOutlineRows(folder: node.path, home: home, outline: outline, drop: drop)
                } label: {
                    row(node).tag(node.path)
                }
            } else {
                row(node).tag(node.path)
            }
        }
    }

    private func row(_ node: DocNode) -> some View {
        let isDir = node.kind == .dir
        let target = isDir ? node.path : home.parent(of: node.path)
        let highlighted = isDir && outline.dropTarget == node.path
        return Label {
            HStack(spacing: 5) {
                Text(DocNames.display(node))
                if home.isPinned(node.path) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Pinned item")
                }
            }
        } icon: {
            Image(systemName: isDir ? (highlighted ? "folder.fill" : "folder") : "doc.text")
        }
        .badge(isDir ? home.fileCount(in: node.path) : 0)
        .padding(.vertical, 3)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(DocsDropHighlight(on: highlighted))
        .draggable(DocsDrag.payload(node.path, selection: outline.selectedPaths)) {
            let count = outline.selectedPaths.contains(node.path) ? outline.selectedPaths.count : 1
            Label(count > 1 ? String(localized: "\(count) items") : DocNames.display(node), systemImage: isDir ? "folder" : "doc.text")
                .padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, target)
        } isTargeted: { outline.hover(node.path, target: target, $0) }
    }
}

/// The tab's last fetch failed: what is shown may be out of date.
private struct HomeErrorBanner: View {
    let home: FilesHomeStore

    var body: some View {
        if let error = home.error {
            StaleBanner(message: error) { Task { await home.load() } }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }
}

private struct DocsDropHighlight: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(on ? 0.22 : 0))
            .padding(.horizontal, -6)
    }
}
