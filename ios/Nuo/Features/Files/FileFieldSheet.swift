import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Files of a `file` column: preview, save a copy, add new ones.
struct FileFieldSheet: View {
    let column: DataColumn
    let files: [DataFileRef]
    let onAdd: (_ name: String, _ data: Data, _ contentType: String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaLoader) private var loader
    @State private var importing = false
    @State private var adding = false
    @State private var loading: DataFileRef?
    @State private var preview: URL?
    @State private var saving: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if files.isEmpty {
                        Text("No files").foregroundStyle(Color.text3)
                    }
                    ForEach(files, id: \.self) { file in
                        line(file)
                    }
                }
                // Nested file dialogs never show: the save and import dialogs sit on sibling sections.
                .fileMover(isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }), file: saving) { result in
                    if case let .failure(failure) = result { error = failure.localizedDescription }
                }
                Section {
                    Button {
                        error = nil
                        importing = true
                    } label: {
                        HStack {
                            Label("Add a file", systemImage: "plus")
                            Spacer()
                            if adding { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(adding)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                    guard case let .success(urls) = result else { return }
                    Task { await add(urls) }
                }
            }
            .navigationTitle(column.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .quickLookPreview($preview)
    }

    private func line(_ file: DataFileRef) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { if let url = await fetch(file) { preview = url } }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperclip").foregroundStyle(Color.accentInk)
                    Text(file.name).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if loading == file {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { if let url = await fetch(file) { saving = url } }
                } label: {
                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(Color.accentInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(file.name)")
            }
        }
        .disabled(loading != nil)
    }

    /// The gateway serves files behind the app's token, so they are downloaded here rather than opened in a browser.
    private func fetch(_ file: DataFileRef) async -> URL? {
        guard let source = file.downloadPath else { return nil }
        loading = file
        defer { loading = nil }
        error = nil
        do {
            let data = try await loader.load(source)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("row-files", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.name.isEmpty ? "fichier" : file.name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            self.error = String(localized: "Could not fetch “\(file.name)”.")
            return nil
        }
    }

    private func add(_ urls: [URL]) async {
        adding = true
        defer { adding = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data else {
                error = String(localized: "Could not read “\(url.lastPathComponent)”.")
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard await onAdd(url.lastPathComponent, data, type) else {
                error = String(localized: "“\(url.lastPathComponent)” could not be added.")
                return
            }
        }
    }
}
