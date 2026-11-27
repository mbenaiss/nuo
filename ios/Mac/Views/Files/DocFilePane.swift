import SwiftUI

/// A PDF, an image or any other file of the docs repo that is not text: shown, moved, renamed or deleted, never edited.
struct DocFilePane: View {
    let path: String
    var inWindow = false
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator: MacNavigator?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaLoader) private var loader
    @State private var failure: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    private var displayName: String { DocNames.display(name: (path as NSString).lastPathComponent) }

    var body: some View {
        DocBinaryPage(path: path, kind: DocFileKind.of(path))
            .navigationTitle(displayName)
            .navigationSubtitle(["Docs", DocNames.folder(of: path)].compactMap { $0 }.joined(separator: " › "))
            .toolbar { toolbar }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                Button("Rename") { Task { await rename() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(displayName)”?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It goes to your documents' trash; the history keeps its content.")
            }
            .alert("Couldn't complete the action", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !inWindow {
            ToolbarItem {
                Button { openWindow(id: MacWindow.doc, value: path) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
                    .help("Open in new window (⇧⌘O)")
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Menu {
                DocsPinButton(path: path)
                DocsMoveMenu(paths: [path], onMove: follow) { failure = $0 }
                Button("Rename…", systemImage: "pencil") {
                    renameText = displayName
                    renaming = true
                }
                Button("Copy Link", systemImage: "link") { copyLink() }
                Button("Share…", systemImage: "square.and.arrow.up") {
                    Task {
                        if let message = await MacDocShare.share(path, loader: loader) { failure = message }
                    }
                }
                Menu("Public Link (Drop)", systemImage: "link") {
                    ForEach(DropLifetime.allCases) { lifetime in
                        Button(lifetime.label) {
                            Task {
                                if let message = await MacDocShare.dropLink(path, lifetime: lifetime, api: session.api) { failure = message }
                            }
                        }
                    }
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

    private func follow(_ moves: [String: String]) {
        guard let moved = FilesHomeStore.path(path, after: moves), moved != path else { return }
        if let navigator, !inWindow { navigator.doc = moved } else { dismiss() }
    }

    private func rename() async {
        do {
            let renamed = try await FilesHomeStore.shared.rename(path, to: renameText)
            if renamed != path { follow([path: renamed]) }
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
}

enum MacDocShare {
    /// Downloads the file, then opens the system share menu; returns a message when the file could not be prepared.
    @MainActor
    static func share(_ path: String, loader: MediaLoader) async -> String? {
        do {
            let file = try await DocShare.file(path) { try await loader.load(DocsPaths.raw($0)) }
            present(file)
            return nil
        } catch {
            return String(localized: "Couldn't prepare sharing: \(error.localizedDescription)")
        }
    }

    /// Publishes the document on drop, copies the link and opens the share menu with it.
    @MainActor
    static func dropLink(_ path: String, lifetime: DropLifetime, api: any NuoAPI) async -> String? {
        do {
            let link = try await api.dropDoc(path: path, ttlMinutes: lifetime.rawValue)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            present(link.url)
            return nil
        } catch {
            return String(localized: "Couldn't create the drop link: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func present(_ item: URL) {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
        // A toolbar menu item has no view to anchor to: the picker opens under the window's top-right corner.
        let top = view.safeAreaInsets.top
        let anchor = NSRect(x: view.bounds.maxX - 60, y: view.isFlipped ? top : view.bounds.maxY - top, width: 1, height: 1)
        NSSharingServicePicker(items: [item]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}
