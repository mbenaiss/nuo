import SwiftUI

struct DocsFolderView: View {
    let path: String
    @Environment(SessionStore.self) private var session
    @State private var home = FilesHomeStore.shared
    @State private var creating = false
    @State private var newName = ""
    @State private var pendingDelete: DocNode?
    @State private var creatingFolder = false
    @State private var renaming: DocNode?
    @State private var renameText = ""
    @State private var failure: String?

    private func row(_ node: DocNode) -> some View {
        let route: FilesRoute = node.kind == .dir ? .folder(node.path) : .doc(node.path)
        let count: Int? = node.kind == .dir ? home.fileCount(in: node.path) : nil
        return NavigationLink(value: route) {
            DocNodeRow(node: node, fileCount: count)
        }
        .buttonStyle(RowPressStyle())
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = DocNames.display(node)
                renaming = node
            }
            DocsMoveMenu(paths: [node.path]) { failure = $0 }
            DocsPinButton(path: node.path)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = node }
        }
    }

    var body: some View {
        let children = home.children(of: path)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if children.isEmpty {
                    WorkspaceEmptyState(symbol: "folder", title: String(localized: "Empty folder"), message: nil, mascot: .sleep)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(children.enumerated()), id: \.element.id) { index, node in
                            row(node)
                            if index < children.count - 1 { Divider().overlay(Color.line).padding(.leading, 62) }
                        }
                    }
                    .groupCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Color.canvas)
        .navigationTitle(DocNames.display(name: (path as NSString).lastPathComponent))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await home.refreshDocs() }
        .confirmationDialog(pendingDelete.map { String(localized: "Delete “\(DocNames.display($0))”?") } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let node = pendingDelete {
                    Task {
                        let failures = await home.delete([node.path])
                        if !failures.isEmpty { failure = failures.joined(separator: "\n") }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDelete.map(deleteMessage) ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("New folder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New document")
            }
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName
                newName = ""
                Task {
                    do { _ = try await home.createFolder(named: name, in: path) } catch { failure = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { node in
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText
                Task {
                    do { _ = try await home.rename(node.path, to: name) } catch { failure = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Operation failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
        .alert("New document", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .task {
            home.attach(session.api)
            if home.docs.isEmpty { await home.load() }
        }
    }

    private func deleteMessage(_ node: DocNode) -> String {
        guard node.kind == .dir else { return String(localized: "It goes to your documents trash; its history keeps its contents.") }
        let count = home.fileCount(in: node.path)
        if count == 0 { return String(localized: "The folder is empty. It goes to your documents trash.") }
        return String(localized: "The folder contains \(count) documents. Everything goes to your documents trash; history keeps their contents.")
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        let slug = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let file = (path.isEmpty ? "" : path + "/") + (slug.isEmpty ? "note" : slug) + ".md"
        guard (try? await session.api.createDoc(path: file, content: "# \(name)\n\n")) != nil else {
            Haptics.error()
            return
        }
        await home.refreshDocs()
        DocView.editOnOpen = file
        WorkspaceRouter.shared.filesPath.append(.doc(file))
    }
}

struct DocView: View {
    let path: String
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var workspace
    @State private var store: DocStore
    @State private var editing = DocsDemo.opensEditor
    @State private var showsSource = false
    /// A document just created from a « + » button opens straight in the editor.
    @MainActor static var editOnOpen: String?
    @State private var conflict: String?
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var failure: String?
    @Environment(\.dismiss) private var dismissDoc
    @Environment(\.openURL) private var systemOpenURL
    @Environment(\.mediaLoader) private var loader
    @State private var sharedFile: SharedDocFile?
    @State private var preparingShare = false

    init(path: String) {
        self.path = path
        // A document with edits still unsaved shows the store its editing session saves through.
        _store = State(initialValue: DocSessions.shared.sessions[path]?.store ?? DocStore(path: path))
    }

    private var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// A page a bot wrote (HTML) is shown rendered; « Code » shows its source like any other document.
    private var webPage: String? {
        guard !showsSource, isWebDocument else { return nil }
        return store.file?.content
    }

    private var isWebDocument: Bool { DocFileKind.isWebPage(path) }

    private var kind: DocFileKind { DocFileKind.of(path) }

    /// A file that is not text is never loaded through the document API, so `store.file` stays nil for it.
    private var unavailable: Bool { kind == .text && store.file == nil }

    private var documentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let file = store.file, isWebDocument {
                    Text(file.content)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let file = store.file {
                    let document = MarkdownDocument.parsed(file.content)
                    meta(file, document: document)
                    if let title = document.title, !(document.blocks.first.map(Self.isTitle) ?? false) {
                        Text(title).font(.largeTitle.bold()).foregroundStyle(Color.ink)
                    }
                    MarkdownView(document: document, basePath: folder) { line in toggle(line) }
                } else if let error = store.error {
                    WorkspaceEmptyState(symbol: "doc.questionmark", title: String(localized: "Document not found"), message: error)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBar(width: 240, height: 28)
                        ForEach(0..<8, id: \.self) { index in SkeletonBar(width: index % 3 == 2 ? 200 : nil, height: 12) }
                    }
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
    }

    var body: some View {
        Group {
            if kind != .text {
                DocBinaryPage(path: path, kind: kind)
            } else if let html = webPage {
                HTMLWebView(source: .html(html)).ignoresSafeArea(edges: .bottom)
            } else {
                documentScroll
            }
        }
        .navigationTitle(DocNames.display(name: (path as NSString).lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isWebDocument {
                ToolbarItem(placement: .primaryAction) {
                    Button(showsSource ? String(localized: "Preview") : String(localized: "Code")) { showsSource.toggle() }
                        .disabled(store.file == nil)
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                if preparingShare {
                    ProgressView()
                } else {
                    Menu("Share", systemImage: "square.and.arrow.up") {
                        Button("Send file", systemImage: "doc") { Task { await share() } }
                        Menu("Public link (drop)", systemImage: "link") {
                            ForEach(DropLifetime.allCases) { lifetime in
                                Button(lifetime.label) { Task { await shareDropLink(lifetime) } }
                            }
                        }
                    }
                    .disabled(unavailable)
                }
            }
            #endif
            if kind == .text {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .disabled(store.file == nil)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Rename", systemImage: "pencil") {
                    renameText = DocNames.display(name: (path as NSString).lastPathComponent)
                    renaming = true
                }
                .disabled(unavailable)
            }
            ToolbarItem(placement: .secondaryAction) {
                DocsMoveMenu(paths: [path], onMove: follow) { failure = $0 }
                    .disabled(unavailable)
            }
            ToolbarItem(placement: .secondaryAction) {
                DocsPinButton(path: path)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(unavailable)
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText
                Task {
                    do {
                        let renamed = try await FilesHomeStore.shared.rename(path, to: name)
                        if renamed != path { follow([path: renamed]) }
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Operation failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
        .confirmationDialog("Delete “\(DocNames.display(name: (path as NSString).lastPathComponent))”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    let failures = await FilesHomeStore.shared.delete([path])
                    if failures.isEmpty { dismissDoc() } else { failure = failures.joined(separator: "\n") }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to your documents trash; its history keeps its contents.")
        }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .refreshable { await store.load() }
        .onAppear {
            if Self.editOnOpen == path, kind == .text {
                Self.editOnOpen = nil
                editing = true
            }
        }
        #if os(iOS)
        .sheet(item: $sharedFile) { file in
            ActivitySheet(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        #endif
        .fullScreenCover(isPresented: $editing) {
            DocEditorView(store: store, onOpenLink: openFromEditor)
        }
        .alert("Edited elsewhere", isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
            Button("Reload") { Task { await store.load() } }
        } message: {
            Text(conflict ?? "")
        }
        .task {
            guard kind == .text else { return }
            RichDocEditor.prewarm()
            store.attach(session.api)
            await store.load()
        }
    }

    private static func isTitle(_ block: MarkdownBlock) -> Bool {
        if case .heading(1, _) = block { return true }
        return false
    }

    private func shareDropLink(_ lifetime: DropLifetime) async {
        preparingShare = true
        defer { preparingShare = false }
        do {
            let link = try await session.api.dropDoc(path: path, ttlMinutes: lifetime.rawValue)
            sharedFile = SharedDocFile(url: link.url)
        } catch {
            failure = String(localized: "Could not create the drop link: \(error.localizedDescription)")
        }
    }

    private func share() async {
        preparingShare = true
        defer { preparingShare = false }
        let loader = loader
        do {
            sharedFile = SharedDocFile(url: try await DocShare.file(path) { try await loader.load(DocsPaths.raw($0)) })
        } catch {
            failure = String(localized: "Could not prepare sharing: \(error.localizedDescription)")
        }
    }

    private func openFromEditor(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            systemOpenURL(url)
        } else {
            editing = false
            _ = handle(url)
        }
    }

    /// The screen shows the document at its new path once it moved.
    private func follow(_ moves: [String: String]) {
        guard let moved = FilesHomeStore.path(path, after: moves),
              let index = workspace.filesPath.lastIndex(of: .doc(path)) else { return }
        workspace.filesPath[index] = .doc(moved)
    }

    private func meta(_ file: DocFile, document: MarkdownDocument) -> some View {
        HStack(spacing: 8) {
            if let folder = DocNames.folder(of: path) {
                Label(folder, systemImage: "folder").labelStyle(TightLabelStyle())
            }
            if let date = file.updatedAt { Text("Edited \(date.relativeLabel)") }
            ForEach(document.tags, id: \.self) { tag in Badge(text: "#\(tag)") }
        }
        .font(.caption)
        .foregroundStyle(Color.text3)
    }

    /// Checking a box in reading mode saves right away, with the conflict check.
    private func toggle(_ line: Int) {
        guard let content = store.file?.content else { return }
        let updated = MarkdownDocument.toggleCheckbox(in: content, line: line)
        Task {
            switch await store.save(updated, baseSha: store.file?.sha) {
            case .saved: break
            case .conflict: conflict = String(localized: "This document changed since you opened it. Reload it, then tick the box again.")
            case let .failed(message, _): conflict = message
            }
        }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "nuo" {
            if workspace.open(url: url) { return .handled }
            return .systemAction
        }
        if let target = DocLink.target(url, from: folder) {
            workspace.filesPath.append(.doc(target))
            return .handled
        }
        return .systemAction
    }
}

/// « Déplacer vers… »: every folder of the docs tree, those that cannot take the items disabled.
struct DocsMoveMenu: View {
    let paths: [String]
    let onMove: ([String: String]) -> Void
    let onFailure: (String) -> Void
    @State private var home = FilesHomeStore.shared

    init(paths: [String], onMove: @escaping ([String: String]) -> Void = { _ in }, onFailure: @escaping (String) -> Void) {
        self.paths = paths
        self.onMove = onMove
        self.onFailure = onFailure
    }

    var body: some View {
        Menu("Move to…", systemImage: "folder") {
            Button("All documents") { move(into: "") }
                .disabled(!home.canMove(paths, into: ""))
            ForEach(home.folders) { folder in
                Button(String(repeating: "    ", count: folder.path.split(separator: "/").count - 1) + DocNames.display(folder)) {
                    move(into: folder.path)
                }
                .disabled(!home.canMove(paths, into: folder.path))
            }
        }
    }

    private func move(into folder: String) {
        Task {
            let result = await home.move(paths, into: folder)
            if !result.moves.isEmpty { onMove(result.moves) }
            if !result.failures.isEmpty { onFailure(result.failures.joined(separator: "\n")) }
        }
    }
}

struct DocsPinButton: View {
    let path: String
    @State private var home = FilesHomeStore.shared

    var body: some View {
        let pinned = home.isPinned(path)
        Button(pinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: pinned ? "pin.slash" : "pin") {
            home.setPinned([path], !pinned)
        }
    }
}

/// The document edited visually like a Notion page, saved on its own; « Avancé » shows the Markdown source.
struct DocEditorView: View {
    let store: DocStore
    var onOpenLink: (URL) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DocEditSession
    @State private var editor: RichDocEditor?
    @State private var source = false
    @State private var lossy = false
    @State private var failure: String?
    @FocusState private var sourceFocused: Bool

    init(store: DocStore, onOpenLink: @escaping (URL) -> Void = { _ in }) {
        self.store = store
        self.onOpenLink = onOpenLink
        _editing = State(initialValue: DocSessions.shared.session(for: store.path, store: store))
    }

    var body: some View {
        NavigationStack {
            Group {
                if source {
                    sourceEditor
                } else if let editor {
                    RichDocumentEditor(session: editing, editor: editor, focusOnLoad: !DocsDemo.opensEditor, onLossy: {
                        lossy = true
                        source = true
                    }, onOpenLink: onOpenLink)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if editor.focused { DocFormatBar(editor: editor) }
                    }
                } else {
                    Color.canvas.onAppear { editor = RichDocEditor.make() }
                }
            }
            .background(Color.canvas)
            .navigationTitle(DocNames.display(name: (store.path as NSString).lastPathComponent))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await finish() } }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(DocNames.display(name: (store.path as NSString).lastPathComponent)).font(.headline).lineLimit(1)
                        if editing.status == .conflict, !editing.conflict {
                            Button("Not saved: resolve…") { editing.reviewConflict() }.font(.caption2)
                        } else {
                            SaveStatusLabel(status: editing.status, dirty: editing.dirty).font(.caption2)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if source {
                            if !lossy {
                                Button("Visual editor", systemImage: "doc.richtext") { Task { await setSource(false) } }
                            }
                        } else {
                            Menu("Advanced", systemImage: "gearshape") {
                                Button("Raw Markdown", systemImage: "chevron.left.forwardslash.chevron.right") { Task { await setSource(true) } }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .alert("The document changed", isPresented: Binding(get: { editing.conflict }, set: { if !$0 { editing.continueEditing() } })) {
                Button("Keep my version", role: .destructive) { Task { await editing.overwrite() } }
                if !editing.missing {
                    Button("Take theirs") {
                        Task {
                            if !(await editing.keepTheirs()) {
                                failure = String(localized: "Could not fetch the other version. Your changes are kept; try again in a moment.")
                            }
                        }
                    }
                }
                Button("Keep editing", role: .cancel) { editing.continueEditing() }
            } message: {
                Text(editing.missing ? String(localized: "This document was deleted or moved elsewhere while you were writing. “Keep my version” recreates it here.") : String(localized: "A bot or another device edited the same passages while you were writing. Your changes are not saved yet."))
            }
            .alert("Could not save", isPresented: Binding(get: { editing.error != nil }, set: { if !$0 { editing.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(editing.error ?? "") }
            .alert("Operation failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
        .interactiveDismissDisabled(editing.dirty)
        .onDisappear {
            let editing = editing
            let editor = editor
            Task {
                await editing.save()
                if let editor { editing.detachEditor(ObjectIdentifier(editor)) }
                DocSessions.shared.release(editing)
            }
        }
        .onAppear {
            DocSessions.shared.acquire(editing)
            if let file = store.file { editing.loaded(file) }
        }
        // Opened before the doc finished loading (deep link, demo): fill in once it arrives.
        .onChange(of: store.file) { _, file in
            if let file { editing.loaded(file) }
        }
    }

    private var sourceEditor: some View {
        VStack(spacing: 0) {
            if lossy {
                Label("This document contains Markdown the visual editor cannot display: it opens as text so nothing is lost.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.chip)
            }
            TextEditor(text: editing.textBinding)
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .focused($sourceFocused)
        }
    }

    private func setSource(_ on: Bool) async {
        if on { await editing.pullEditor() }
        source = on
        if on { sourceFocused = true }
    }

    private func finish() async {
        editor?.blur()
        await editing.save()
        if !editing.conflict, !editing.dirty { dismiss() }
    }
}

/// Formatting bar above the keyboard: add a block, turn the block into another, styles, colors, undo.
struct DocFormatBar: View {
    let editor: RichDocEditor

    private static let blocks: [(id: String, label: String, symbol: String)] = [
        ("text", String(localized: "Text"), "textformat"), ("h1", String(localized: "Heading 1"), "textformat.size.larger"), ("h2", String(localized: "Heading 2"), "textformat.size"),
        ("h3", String(localized: "Heading 3"), "textformat.size.smaller"), ("bullet", String(localized: "Bulleted list"), "list.bullet"), ("numbered", String(localized: "Numbered list"), "list.number"),
        ("todo", String(localized: "To-do list"), "checklist"), ("toggle", String(localized: "Toggle"), "chevron.right.circle"), ("quote", String(localized: "Quote"), "text.quote"),
        ("callout", String(localized: "Callout"), "lightbulb"), ("code", String(localized: "Code block"), "chevron.left.forwardslash.chevron.right"),
    ]
    private static let colors: [(id: String, label: String, hex: UInt32)] = [
        ("gray", String(localized: "Gray"), 0x787774), ("brown", String(localized: "Brown"), 0x9F6B53), ("orange", String(localized: "Orange"), 0xD9730D), ("yellow", String(localized: "Yellow"), 0xCB912F),
        ("green", String(localized: "Green"), 0x448361), ("blue", String(localized: "Blue"), 0x337EA9), ("purple", String(localized: "Purple"), 0x9065B0), ("pink", String(localized: "Pink"), 0xC14C8A), ("red", String(localized: "Red"), 0xD44C47),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                button("plus", "Add a block") { editor.command("insert") }
                Menu {
                    Section("Turn into") {
                        ForEach(Self.blocks, id: \.id) { block in
                            Button(block.label, systemImage: block.symbol) { editor.command("turn", block.id) }
                        }
                    }
                    Menu("Text color", systemImage: "paintbrush") {
                        Button("Default") { editor.command("color") }
                        ForEach(Self.colors, id: \.id) { color in
                            Button { editor.command("color", color.id) } label: { Label(color.label, systemImage: "circle.fill").tint(Color(hex: color.hex)) }
                        }
                    }
                    Menu("Background color", systemImage: "highlighter") {
                        Button("No background") { editor.command("background") }
                        ForEach(Self.colors, id: \.id) { color in
                            Button { editor.command("background", color.id) } label: { Label(color.label, systemImage: "square.fill").tint(Color(hex: color.hex)) }
                        }
                    }
                } label: { icon("textformat", active: false) }
                .accessibilityLabel("Text style")
                button("checklist", "To-do list", active: editor.format.block == "todo") { editor.command("turn", editor.format.block == "todo" ? "text" : "todo") }
                button("list.bullet", "Bulleted list", active: editor.format.block == "bullet") { editor.command("turn", editor.format.block == "bullet" ? "text" : "bullet") }
                divider
                button("bold", "Bold", active: editor.format.bold) { editor.command("bold") }
                button("italic", "Italic", active: editor.format.italic) { editor.command("italic") }
                button("underline", "Underline", active: editor.format.underline) { editor.command("underline") }
                button("strikethrough", "Strikethrough", active: editor.format.strike) { editor.command("strike") }
                button("link", "Link", active: editor.format.link) { editor.command("link") }
                button("at", "Mention a document") { editor.command("doclink") }
                Menu {
                    Button("Photo library", systemImage: "photo.on.rectangle") { editor.command("pick", "image") }
                    #if os(iOS)
                    if DocCamera.available {
                        Button("Camera", systemImage: "camera") { editor.command("pick", "camera") }
                    }
                    #endif
                    Button("File or PDF", systemImage: "doc") { editor.command("pick", "file") }
                } label: { icon("photo", active: false) }
                .accessibilityLabel("Add a photo or file")
                divider
                button("decrease.indent", "Outdent") { editor.command("outdent") }
                button("increase.indent", "Indent") { editor.command("indent") }
                button("square.grid.3x3.square", "Block options") { editor.command("blockMenu") }
                divider
                button("arrow.uturn.backward", "Undo", enabled: editor.format.canUndo) { editor.command("undo") }
                button("arrow.uturn.forward", "Redo", enabled: editor.format.canRedo) { editor.command("redo") }
                button("keyboard.chevron.compact.down", "Hide keyboard") { editor.blur() }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var divider: some View {
        Rectangle().fill(Color.line).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func icon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(active ? Color.accent : Color.ink)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func button(_ symbol: String, _ label: LocalizedStringKey, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: { icon(symbol, active: active) }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

enum DocsDemo {
    /// `-demoDocEditor` opens the editor of the doc shown at launch.
    static var opensEditor: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoDocEditor")
    }
}
