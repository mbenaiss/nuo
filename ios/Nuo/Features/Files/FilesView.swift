import Charts
import SwiftUI

/// Fichiers tab: data collections, a link to the dashboards and docs, with one search across rows and docs.
struct FilesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var home = FilesHomeStore.shared
    @State private var search = ""
    @State private var debouncer = Debouncer()
    @State private var creatingDoc = false
    @State private var creatingFolder = false
    @State private var newName = ""
    @State private var createFailure: String?

    var body: some View {
        @Bindable var workspace = workspace
        NavigationStack(path: $workspace.filesPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    if debouncer.value.isEmpty || search.isEmpty {
                        content
                    } else {
                        GlobalSearchResults(query: debouncer.value)
                    }
                }
                .onChange(of: home.loaded) { _, loaded in
                    if loaded, let section = FilesDemo.section {
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            proxy.scrollTo(section, anchor: .top)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.canvas)
            .navigationTitle("Files")
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Invoices, customers, notes…")
            .onChange(of: search) { _, value in debouncer.send(value) }
            .refreshable { await home.load() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New document", systemImage: "square.and.pencil") { creatingDoc = true }
                        Button("New folder", systemImage: "folder.badge.plus") { creatingFolder = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create")
                }
            }
            .alert("New document", isPresented: $creatingDoc) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await createDoc() } }
                Button("Cancel", role: .cancel) { newName = "" }
            }
            .alert("New folder", isPresented: $creatingFolder) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await createFolder() } }
                Button("Cancel", role: .cancel) { newName = "" }
            }
            .alert("Could not create", isPresented: Binding(get: { createFailure != nil }, set: { if !$0 { createFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(createFailure ?? "") }
            .navigationDestination(for: FilesRoute.self) { route in
                switch route {
                case let .collection(id): CollectionView(collectionId: id)
                case let .row(collection, id): RowDetailView(collectionId: collection, rowId: id, seed: nil)
                case .dashboards: DashboardsListView()
                case let .dashboard(slug): DashboardView(slug: slug)
                case let .folder(path): DocsFolderView(path: path)
                case let .doc(path): DocView(path: path)
                }
            }
            .task {
                home.attach(session.api)
                await home.loadIfStale()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                home.markStale()
                if workspace.tab == .files { Task { await home.load() } }
            }
        }
    }

    private func createDoc() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        let slug = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let file = (slug.isEmpty ? "note" : slug) + ".md"
        do {
            _ = try await session.api.createDoc(path: file, content: "# \(name)\n\n")
        } catch {
            createFailure = error.localizedDescription
            return
        }
        await home.refreshDocs()
        DocView.editOnOpen = file
        workspace.filesPath.append(.doc(file))
    }

    private func createFolder() async {
        let name = newName
        newName = ""
        do {
            let path = try await home.createFolder(named: name, in: "")
            workspace.filesPath.append(.folder(path))
        } catch {
            createFailure = error.localizedDescription
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let error = home.error, home.loaded {
                StaleBanner(message: error) { Task { await home.load() } }
            }
            collectionsSection
            dashboardsLink
            docsSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 30)
    }

    // MARK: Dashboards

    /// One row rather than the cards: the home starts with the collections, the dashboards have their own screen.
    @ViewBuilder
    private var dashboardsLink: some View {
        if !home.dashboards.isEmpty {
            NavigationLink(value: FilesRoute.dashboards) {
                HStack(spacing: 12) {
                    EmojiTile(emoji: "📊")
                    Text("Dashboards").font(.body.weight(.medium)).foregroundStyle(Color.ink)
                    Spacer()
                    Text("\(home.dashboards.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.text3)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .groupCard()
        }
    }

    // MARK: Collections

    @ViewBuilder
    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Data"))
            if !home.loaded {
                SkeletonRows(count: 4)
            } else if home.collections.isEmpty {
                Text("No collections.").font(.subheadline).foregroundStyle(Color.text2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(home.collections.enumerated()), id: \.element.id) { index, collection in
                        NavigationLink(value: FilesRoute.collection(collection.id)) {
                            HStack(spacing: 12) {
                                EmojiTile(emoji: collection.emoji ?? "🗂️")
                                Text(collection.label).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                                Spacer()
                                Text("\(collection.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.text3)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < home.collections.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                    }
                }
                .groupCard()
            }
        }
    }

    // MARK: Docs

    @ViewBuilder
    private var docsSection: some View {
        let top = home.children(of: "")
        let pinned = home.pinnedNodes
        VStack(alignment: .leading, spacing: 10) {
            if !pinned.isEmpty {
                SectionHeader(title: String(localized: "Pinned"))
                VStack(spacing: 0) {
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, node in
                        NavigationLink(value: node.kind == .dir ? FilesRoute.folder(node.path) : FilesRoute.doc(node.path)) {
                            DocNodeRow(node: node, fileCount: node.kind == .dir ? home.fileCount(in: node.path) : nil, showsFolder: true)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { DocsPinButton(path: node.path) }
                        if index < pinned.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                    }
                }
                .groupCard()
                .padding(.bottom, 14)
            }
            SectionHeader(title: String(localized: "Docs"))
            if !home.loaded {
                SkeletonRows(count: 3)
            } else if top.isEmpty {
                Text("The docs repository is empty.").font(.subheadline).foregroundStyle(Color.text2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, node in
                        NavigationLink(value: node.kind == .dir ? FilesRoute.folder(node.path) : FilesRoute.doc(node.path)) {
                            DocNodeRow(node: node, fileCount: node.kind == .dir ? home.fileCount(in: node.path) : nil)
                        }
                        .buttonStyle(.plain)
                        if index < top.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                    }
                }
                .groupCard()
                let recent = Array(home.recentDocs.filter { $0.path.contains("/") }.prefix(3))
                if !recent.isEmpty {
                    SectionHeader(title: String(localized: "Recently edited")).padding(.top, 14)
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, node in
                            NavigationLink(value: FilesRoute.doc(node.path)) {
                                DocNodeRow(node: node, fileCount: nil, showsFolder: true)
                            }
                            .buttonStyle(.plain)
                            if index < recent.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                        }
                    }
                    .groupCard()
                }
            }
        }
        .id("docs")
    }
}

struct EmojiTile: View {
    let emoji: String
    var size: CGFloat = 36

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct DocNodeRow: View {
    let node: DocNode
    let fileCount: Int?
    var showsFolder = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.kind == .dir ? "folder.fill" : "doc.text")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(node.kind == .dir ? Color.accent : Color.text2)
                .frame(width: 36, height: 36)
                .background(node.kind == .dir ? Color.accentSoft : Color.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(DocNames.display(node)).font(.body.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                if showsFolder, let folder = DocNames.folder(of: node.path) {
                    Text(folder).font(.caption).foregroundStyle(Color.text3)
                }
            }
            Spacer()
            if let fileCount {
                Text("\(fileCount)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.text3)
            } else if let date = node.updatedAt {
                Text(date.relativeLabel).font(.caption).foregroundStyle(Color.text3)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

enum DocNames {
    /// "plan-2026.md" → "Plan 2026", folders capitalised.
    static func display(_ node: DocNode) -> String { display(name: node.name) }

    static func display(name: String) -> String {
        var base = name
        if base.lowercased().hasSuffix(".md") { base = String(base.dropLast(3)) }
        base = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    static func folder(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash]).split(separator: "/").map { display(name: String($0)) }.joined(separator: " › ")
    }

    /// Display name of the folder `path` ("" is the top level).
    static func folderName(_ path: String) -> String {
        path.isEmpty ? String(localized: "All documents") : display(name: (path as NSString).lastPathComponent)
    }

    /// A typed name as a file or folder name: dashes for spaces (shown back as spaces), no slash, not hidden.
    /// A document keeps the extension of `original` (".md" for a new one).
    static func fileName(from input: String, original: String? = nil, isFolder: Bool) -> String? {
        var base = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[/\\:]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        while base.hasPrefix(".") { base.removeFirst() }
        guard !base.isEmpty else { return nil }
        if !isFolder {
            let ext = original.map { ($0 as NSString).pathExtension } ?? "md"
            if !ext.isEmpty, !base.lowercased().hasSuffix("." + ext.lowercased()) { base += "." + ext }
        }
        return base
    }
}

/// Every dashboard as cards, reached from the Fichiers home.
struct DashboardsListView: View {
    @Environment(SessionStore.self) private var session
    @State private var home = FilesHomeStore.shared

    var body: some View {
        ScrollView {
            Group {
                if !home.loaded {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                SkeletonBar(width: 34, height: 34)
                                SkeletonBar(width: 90, height: 12)
                                SkeletonBar(width: 120, height: 22)
                            }
                            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                            .card()
                        }
                    }
                } else if home.dashboards.isEmpty {
                    WorkspaceEmptyState(symbol: "chart.bar.xaxis", title: String(localized: "No dashboards"), message: String(localized: "Ask a bot to create one in dashboards/."))
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(home.dashboards) { summary in
                            NavigationLink(value: FilesRoute.dashboard(summary.slug)) {
                                DashboardCard(summary: summary, preview: home.previews[summary.slug])
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle("Dashboards")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await home.load() }
        .task {
            home.attach(session.api)
            await home.loadIfStale()
        }
    }
}

/// Dashboard card on the dashboards screen: emoji, title, the first figure and a sparkline when available.
struct DashboardCard: View {
    let summary: DashboardSummary
    let preview: Dashboard?

    private var figure: DashboardBlock? { preview?.blocks.first { $0.type == .number } }
    private var spark: [DashboardBlock.Point] {
        guard let block = preview?.blocks.first(where: { $0.type == .line || $0.type == .bar }), let series = block.series else { return [] }
        if series.count == 1 { return series[0].points }
        var totals: [String: Double] = [:]
        var order: [String] = []
        for point in series.flatMap(\.points) {
            let key = point.x.string ?? ""
            if totals[key] == nil { order.append(key) }
            totals[key, default: 0] += point.y ?? 0
        }
        return order.map { DashboardBlock.Point(x: .string($0), y: totals[$0]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EmojiTile(emoji: summary.emoji ?? "📊", size: 34)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
            }
            Text(summary.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
            if let figure, let value = figure.value {
                VStack(alignment: .leading, spacing: 1) {
                    Text(figure.format == "money" ? ValueFormat.money(value.double ?? 0, cents: false) : ValueFormat.formatted(value, format: figure.format))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(figure.title).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                }
            } else if let description = summary.description {
                Text(description).font(.caption).foregroundStyle(Color.text2).lineLimit(2)
            }
            Spacer(minLength: 0)
            if spark.count > 1 {
                Chart(Array(spark.enumerated()), id: \.offset) { index, point in
                    AreaMark(x: .value("x", index), y: .value("y", point.y ?? 0))
                        .foregroundStyle(LinearGradient(colors: [Color.accent.opacity(0.28), Color.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("x", index), y: .value("y", point.y ?? 0))
                        .foregroundStyle(Color.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 34)
                .allowsHitTesting(false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.line))
        .multilineTextAlignment(.leading)
    }
}

/// Results of the Fichiers search: rows (title columns) and lines of docs.
struct GlobalSearchResults: View {
    let query: String
    @Environment(SessionStore.self) private var session
    @State private var rows: [DataSearchHit] = []
    @State private var docs: [DocSearchHit] = []
    @State private var searching = true
    private let home = FilesHomeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            let places = matchingPlaces
            if !places.isEmpty {
                section(String(localized: "Shortcuts")) {
                    ForEach(Array(places.enumerated()), id: \.offset) { index, place in
                        NavigationLink(value: place.route) {
                            resultRow(symbol: nil, emoji: place.emoji, title: place.title, subtitle: place.subtitle)
                        }
                        .buttonStyle(.plain)
                        if index < places.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                    }
                }
            }
            if !rows.isEmpty {
                section(String(localized: "Data")) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, hit in
                        let collection = home.collection(hit.collection)
                        NavigationLink(value: FilesRoute.row(collection: hit.collection, id: hit.row.id)) {
                            resultRow(symbol: nil, emoji: collection?.emoji ?? "🗂️", title: hit.row.title, subtitle: collection?.label ?? hit.collection)
                        }
                        .buttonStyle(.plain)
                        if index < rows.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                    }
                }
            }
            if !docs.isEmpty {
                section(String(localized: "Docs")) {
                    ForEach(Array(docs.enumerated()), id: \.offset) { index, hit in
                        NavigationLink(value: FilesRoute.doc(hit.path)) {
                            resultRow(symbol: "doc.text", emoji: nil, title: highlight(hit.snippet),
                                      subtitle: String(localized: "\(DocNames.display(name: (hit.path as NSString).lastPathComponent)) · line \(hit.line)"))
                        }
                        .buttonStyle(.plain)
                        if index < docs.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                    }
                }
            }
            if searching && rows.isEmpty && docs.isEmpty {
                SkeletonRows(count: 4)
            } else if !searching && rows.isEmpty && docs.isEmpty && places.isEmpty {
                WorkspaceEmptyState(symbol: "magnifyingglass", title: String(localized: "No results"), message: String(localized: "Nothing matches “\(query)”."))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 30)
        .task(id: query) { await run() }
    }

    private var matchingPlaces: [(title: String, subtitle: String, emoji: String, route: FilesRoute)] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func hit(_ text: String) -> Bool { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle) }
        let dashboards = home.dashboards.filter { hit($0.title) }.map { ($0.title, String(localized: "Dashboard"), $0.emoji ?? "📊", FilesRoute.dashboard($0.slug)) }
        let collections = home.collections.filter { hit($0.label) }.map { ($0.label, String(localized: "\($0.count) items"), $0.emoji ?? "🗂️", FilesRoute.collection($0.id)) }
        return dashboards + collections
    }

    private func run() async {
        searching = true
        async let rowHits = try? session.api.searchData(query)
        async let docHits = try? session.api.searchDocs(query)
        let (r, d) = await (rowHits, docHits)
        guard !Task.isCancelled else { return }
        withAnimation(.snappy(duration: 0.2)) {
            rows = r ?? []
            docs = d ?? []
            searching = false
        }
    }

    private func highlight(_ snippet: String) -> String {
        snippet.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*[] ")).trimmingCharacters(in: .whitespaces)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            VStack(spacing: 0, content: content).groupCard()
        }
    }

    private func resultRow(symbol: String?, emoji: String?, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            if let emoji {
                EmojiTile(emoji: emoji)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.text2)
                    .frame(width: 36, height: 36).background(Color.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(Color.text3).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

enum FilesDemo {
    /// `-demoFilesSection docs` scrolls the Fichiers home to that section.
    static var section: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoFilesSection"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
