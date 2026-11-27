import SwiftUI
import UniformTypeIdentifiers

enum DocMode: String {
    /// Visual editor, the default: no Markdown in sight.
    case edit
    case read
    /// « Avancé »: the Markdown source, alone or next to a preview.
    case markdown, split
}

/// A file of the docs repo: text opens in the editor, a PDF or any other file in a viewer that never writes it back.
struct DocPane: View {
    let path: String
    var inWindow = false

    var body: some View {
        if DocFileKind.of(path) == .text {
            MarkdownDocPane(path: path, inWindow: inWindow)
        } else {
            DocFilePane(path: path, inWindow: inWindow)
        }
    }
}

/// A doc edited in place like a Notion page and saved on its own a moment after each change. Saving sends the sha the
/// edits started from: a concurrent edit by an agent is merged when it touched other lines, and surfaces as a conflict
/// otherwise. The editing session is the app's one for this path (`DocSessions`), shared with a window showing it.
private struct MarkdownDocPane: View {
    let path: String
    var inWindow = false
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator: MacNavigator?
    @Environment(WorkspaceRouter.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @AppStorage("docs.mode") private var preferredMode = DocMode.edit.rawValue
    @State private var editing: DocEditSession
    @State private var editor: RichDocEditor?
    @State private var mode: DocMode
    /// The visual editor would have dropped something in this file: it stays in Markdown.
    @State private var lossy = false
    @State private var preview = MarkdownDocument("")
    @State private var failure: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var showsSource = false
    @FocusState private var sourceFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaLoader) private var loader

    init(path: String, inWindow: Bool = false) {
        self.path = path
        self.inWindow = inWindow
        _editing = State(initialValue: DocSessions.shared.session(for: path))
        let stored = DocMode(rawValue: UserDefaults.standard.string(forKey: "docs.mode") ?? "") ?? .edit
        _mode = State(initialValue: DocsDemo.opensEditor ? .edit : stored)
    }

    private var store: DocStore { editing.store }

    private var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Split from `body`: as one chain, the modifiers take the type checker past its time limit on slower machines.
    private var presented: some View {
        Group {
            if store.file == nil {
                if let error = store.error {
                    WorkspaceEmptyState(symbol: "doc.questionmark", title: String(localized: "Document not found"), message: error)
                } else {
                    ProgressView()
                }
            } else if DocFileKind.isWebPage(path), !showsSource {
                HTMLWebView(source: .html(editing.dirty ? editing.text : store.file?.content ?? ""))
            } else {
                switch mode {
                case .read: reader(MarkdownDocument.parsed(editing.dirty ? editing.text : store.file?.content ?? ""))
                case .edit: visualEditor
                case .markdown: source
                case .split:
                    HSplitView {
                        source.frame(minWidth: 320)
                        reader(preview).frame(minWidth: 320)
                    }
                }
            }
        }
        .background(Color.canvas)
        .navigationTitle(DocNames.display(name: (path as NSString).lastPathComponent))
        .navigationSubtitle(["Docs", DocNames.folder(of: path)].compactMap { $0 }.joined(separator: " › "))
        .toolbar { toolbar }
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .alert("The document changed", isPresented: Binding(get: { editing.conflict }, set: { if !$0 { editing.continueEditing() } })) {
            Button("Keep my version", role: .destructive) { Task { await editing.overwrite() } }
            if !editing.missing {
                Button("Take theirs") {
                    Task {
                        if !(await editing.keepTheirs()) {
                            failure = String(localized: "Couldn't fetch the other version. Your changes are kept; try again in a moment.")
                        }
                    }
                }
            }
            Button("Keep editing", role: .cancel) { editing.continueEditing() }
        } message: {
            Text(editing.missing ? String(localized: "This document was deleted or moved elsewhere while you were writing. “Keep my version” recreates it here.") : String(localized: "An agent or another device changed the same passages while you were writing. Your changes are not saved yet."))
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(DocNames.display(name: (path as NSString).lastPathComponent))”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to your documents' trash; the history keeps its content.")
        }
        .fileExporter(isPresented: $exporting, document: MarkdownFile(text: editing.text), contentType: .markdownText,
                      defaultFilename: (path as NSString).lastPathComponent) { _ in }
        .alert("Couldn't save", isPresented: Binding(get: { editing.error != nil }, set: { if !$0 { editing.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(editing.error ?? "") }
        .alert("Couldn't complete the action", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    var body: some View {
        presented
        .task(id: navigator?.refreshTick ?? 0) {
            store.attach(session.api)
            if let file = store.file { editing.loaded(file) }
            await store.load()
            if let file = store.file { editing.loaded(file) }
        }
        .task(id: editing.text) {
            guard mode == .split else { return }
            try? await Task.sleep(for: .milliseconds(120))
            let source = editing.text
            preview = await Task.detached(priority: .userInitiated) { MarkdownDocument(source) }.value
        }
        .onChange(of: mode) { old, new in modeChanged(from: old, to: new) }
        .onAppear {
            DocSessions.registerForQuit()
            DocSessions.shared.acquire(editing)
        }
        .onDisappear {
            let editing = editing
            let editor = editor
            Task {
                await editing.save()
                if let editor { editing.detachEditor(ObjectIdentifier(editor)) }
                DocSessions.shared.release(editing)
            }
        }
    }

    private func modeChanged(from old: DocMode, to new: DocMode) {
        let showsSource = new == .markdown || new == .split
        if new == .split { preview = MarkdownDocument(editing.text) }
        if showsSource { sourceFocused = true }
        if (new == .edit || new == .read) && !lossy { preferredMode = new.rawValue }
        // Back in the visual editor, it picks up the source edits through the session's revision.
        if old == .edit { Task { await flushEditor() } }
    }

    // MARK: Views

    private var visualEditor: some View {
        Group {
            if let editor {
                RichDocumentEditor(session: editing, editor: editor, focusOnLoad: !DocsDemo.opensEditor && editing.text.count < 40, onLossy: {
                    lossy = true
                    mode = .markdown
                }, onOpenLink: { url in _ = handle(url) })
            } else {
                Color.canvas.onAppear { editor = RichDocEditor.make() }
            }
        }
    }

    private func reader(_ document: MarkdownDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    if let date = store.file?.updatedAt { Text("Modified \(date.relativeLabel)") }
                    ForEach(document.tags, id: \.self) { tag in Badge(text: "#\(tag)") }
                }
                .font(.caption)
                .foregroundStyle(Color.text3)
                if let title = document.title, !(document.blocks.first.map(Self.isTitle) ?? false) {
                    Text(title).font(.largeTitle.bold()).foregroundStyle(Color.ink)
                }
                MarkdownView(document: document, basePath: folder) { line in toggle(line) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var source: some View {
        VStack(spacing: 0) {
            if lossy {
                Label("This document contains Markdown the visual editor can't display: it opens as text so nothing is lost.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Color.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.chip)
            }
            TextEditor(text: editing.textBinding)
                .font(.system(size: 14, design: .monospaced))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .contentMargins(.vertical, 20, for: .scrollContent)
                .focused($sourceFocused)
                .background(Color.card)
        }
    }

    private static func isTitle(_ block: MarkdownBlock) -> Bool {
        if case .heading(1, _) = block { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            SaveStatusLabel(status: editing.status, dirty: editing.dirty)
        }
        .sharedBackgroundVisibility(.hidden)
        if editing.status == .conflict, !editing.conflict {
            ToolbarItem {
                Button("Resolve…") { editing.reviewConflict() }
                    .help("Choose between your version and the one changed elsewhere")
            }
        }
        if DocFileKind.isWebPage(path) {
            ToolbarItem {
                Button(showsSource ? String(localized: "Preview") : String(localized: "Code")) { showsSource.toggle() }
                    .disabled(store.file == nil)
                    .help(showsSource ? String(localized: "Show the rendered page") : String(localized: "Show and edit the page code"))
            }
            ToolbarSpacer(.fixed)
        }
        if mode == .markdown || mode == .split, !lossy, !DocFileKind.isWebPage(path) || showsSource {
            ToolbarItem {
                Button { mode = .edit } label: { Label("Visual editor", systemImage: "doc.richtext") }
                    .help("Back to the visual editor")
            }
            ToolbarSpacer(.fixed)
        }
        if !inWindow {
            ToolbarItem {
                Button { openWindow(id: MacWindow.doc, value: path) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
                    .help("Open in new window (⇧⌘O)")
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Menu {
                Button("Save Now", systemImage: "arrow.down.doc") { Task { await saveNow() } }
                    .keyboardShortcut("s")
                Divider()
                DocsPinButton(path: path)
                DocsMoveMenu(paths: [path], onMove: follow) { failure = $0 }
                Button("Rename…", systemImage: "pencil") {
                    renameText = DocNames.display(name: (path as NSString).lastPathComponent)
                    renaming = true
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { Task { await duplicate() } }
                Button("Copy Link", systemImage: "link") { copyLink() }
                Button("Share…", systemImage: "square.and.arrow.up") {
                    Task {
                        await saveNow()
                        if let message = await MacDocShare.share(path, loader: loader) { failure = message }
                    }
                }
                Menu("Public Link (Drop)", systemImage: "link") {
                    ForEach(DropLifetime.allCases) { lifetime in
                        Button(lifetime.label) {
                            Task {
                                await saveNow()
                                if let message = await MacDocShare.dropLink(path, lifetime: lifetime, api: session.api) { failure = message }
                            }
                        }
                    }
                }
                Button("Export as Markdown…", systemImage: "square.and.arrow.up") {
                    Task {
                        await flushEditor()
                        exporting = true
                    }
                }
                Divider()
                if mode == .read {
                    Button("Edit", systemImage: "pencil.line") { mode = lossy ? .markdown : .edit }
                } else {
                    Button("Reading Mode", systemImage: "book") { mode = .read }
                }
                Menu("Advanced", systemImage: "gearshape") {
                    Button("Raw Markdown", systemImage: "chevron.left.forwardslash.chevron.right") { mode = .markdown }
                    Button("Markdown and Preview", systemImage: "rectangle.split.2x1") { mode = .split }
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("More actions")
        }
    }

    // MARK: Document actions

    private func follow(_ moves: [String: String]) {
        guard let moved = FilesHomeStore.path(path, after: moves), moved != path else { return }
        if let navigator, !inWindow { navigator.doc = moved } else { dismiss() }
    }

    private func rename() async {
        await saveNow()
        do {
            let renamed = try await FilesHomeStore.shared.rename(path, to: renameText)
            if renamed != path { follow([path: renamed]) }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func duplicate() async {
        await saveNow()
        let stem = (path as NSString).deletingPathExtension
        var copy = stem + "-copie.md"
        var n = 2
        while FilesHomeStore.shared.node(copy) != nil {
            copy = "\(stem)-copie-\(n).md"
            n += 1
        }
        do {
            _ = try await session.api.createDoc(path: copy, content: editing.text)
            await FilesHomeStore.shared.refreshDocs()
            if let navigator, !inWindow { navigator.doc = copy } else { openWindow(id: MacWindow.doc, value: copy) }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func copyLink() {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("nuo://docs/\(encoded)", forType: .string)
    }

    private func delete() async {
        let failures = await FilesHomeStore.shared.delete([path])
        if !failures.isEmpty {
            failure = failures.joined(separator: "\n")
        } else if let navigator, !inWindow {
            navigator.doc = nil
        } else {
            dismiss()
        }
    }

    // MARK: Editing

    private func flushEditor() async {
        await editing.pullEditor()
    }

    private func saveNow() async {
        if mode == .edit { await flushEditor() }
        await editing.save()
    }

    private func toggle(_ line: Int) {
        guard let content = store.file?.content, !editing.dirty else { return }
        let updated = MarkdownDocument.toggleCheckbox(in: content, line: line)
        editing.edited(updated)
        Task { await editing.save() }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        if AppIdentity.isAppScheme(url.scheme) {
            return workspace.open(url: url) ? .handled : .systemAction
        }
        if let target = DocLink.target(url, from: folder) {
            if let navigator, !inWindow { navigator.doc = target } else { openWindow(id: MacWindow.doc, value: target) }
            return .handled
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return .handled
        }
        return .systemAction
    }
}

struct MarkdownFile: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .plainText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    static let markdownText = UTType("net.daringfireball.markdown") ?? .plainText
}

struct DocWindow: View {
    let path: String

    var body: some View {
        NavigationStack {
            DocPane(path: path, inWindow: true)
        }
        .frame(minWidth: 560, minHeight: 420)
        .hiddenFromScreenSharing(path.hasPrefix("reunions/"))
    }
}
