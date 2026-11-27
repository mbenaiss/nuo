import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The visual editor wired to a `DocEditSession`: content in and out, uploads next to the document, file previews.
struct RichDocumentEditor: View {
    let session: DocEditSession
    let editor: RichDocEditor
    var focusOnLoad = false
    /// The editor could not show this document without losing content: the caller switches to raw Markdown.
    var onLossy: () -> Void = {}
    var onOpenLink: (URL) -> Void = { _ in }
    @Environment(\.mediaLoader) private var mediaLoader
    @Environment(\.colorScheme) private var colorScheme
    @State private var home = FilesHomeStore.shared
    @State private var didLoad = false
    @State private var picking: (id: String, accept: String)?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var preview: URL?
    @State private var failure: String?

    private var folder: String { (session.store.path as NSString).deletingLastPathComponent }

    var body: some View {
        RichDocEditorView(editor: editor)
            .task(id: session.externalRevision) { sync() }
            .onChange(of: home.docs) { _, _ in editor.setFiles(sizes: sizes, docs: docPaths) }
            .onAppear(perform: wire)
            .onDisappear(perform: unwire)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: contentTypes(picking?.accept), allowsMultipleSelection: false) { result in
                guard let id = picking?.id else { return }
                switch result {
                case let .success(urls):
                    if let url = urls.first { upload(id: id, file: url) } else { editor.uploadFailed(id: id, message: "") }
                case .failure: editor.uploadFailed(id: id, message: "")
                }
            } onCancellation: {
                if let id = picking?.id { editor.uploadFailed(id: id, message: "") }
            }
            #if os(iOS)
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let id = picking?.id else { return }
                guard let item else { return }
                uploading.insert(id)
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
                    photoItem = nil
                    guard let data else { return editor.uploadFailed(id: id, message: String(localized: "Could not read the photo.")) }
                    let name = "photo-\(Int(Date().timeIntervalSince1970)).\(type.preferredFilenameExtension ?? "jpg")"
                    await send(id: id, name: name, mime: type.preferredMIMEType ?? "image/jpeg", data: data)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocCamera { image in
                    showCamera = false
                    guard let id = picking?.id else { return }
                    guard let image, let data = image.jpegData(compressionQuality: 0.85) else { return editor.uploadFailed(id: id, message: "") }
                    uploading.insert(id)
                    Task { await send(id: id, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg", mime: "image/jpeg", data: data) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: showPhotos) { _, shown in
                if !shown, photoItem == nil, let id = picking?.id, !uploading.contains(id) { editor.uploadFailed(id: id, message: "") }
            }
            #endif
            .quickLookPreview($preview)
            .alert("Could not open the file", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
    }

    @State private var uploading = Set<String>()

    private var sizes: [String: Int] {
        Dictionary(home.docs.filter { $0.kind == .file }.map { ($0.path, $0.size ?? 0) }, uniquingKeysWith: { a, _ in a })
    }

    private var docPaths: [String] {
        home.docs.filter { $0.kind == .file && $0.path.lowercased().hasSuffix(".md") && $0.path != session.store.path }.map(\.path)
    }

    private func sync() {
        guard session.base != nil else { return }
        let id = ObjectIdentifier(editor)
        if !didLoad {
            editor.load(markdown: session.text, basePath: folder, sizes: sizes, docs: docPaths, dark: colorScheme == .dark, focus: focusOnLoad)
            didLoad = true
        } else if session.needsSync(id) {
            editor.setMarkdown(session.text)
        } else {
            return
        }
        session.synced(id)
    }

    private func wire() {
        let loader = mediaLoader
        editor.loader = { path in try await loader.load(DocsPaths.raw(path)) }
        let id = ObjectIdentifier(editor)
        editor.onChanged = { session.editorChanged(id) }
        // Strong on purpose: the last save after leaving the document still needs the editor; the screen detaches
        // it once that save is done.
        let editor = editor
        session.attachEditor(id) { await editor.markdown() }
        editor.onLossy = onLossy
        editor.onOpenLink = { href in
            if let url = URL(string: href) ?? URL(string: href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") { onOpenLink(url) }
        }
        editor.onOpenFile = { src, name in open(src: src, name: name) }
        editor.onUpload = { id, name, mime, data in
            uploading.insert(id)
            Task { await send(id: id, name: name, mime: mime, data: data) }
        }
        editor.onPick = { id, accept in
            picking = (id, accept)
            #if os(iOS)
            switch accept {
            case "image": showPhotos = true
            case "camera": showCamera = true
            default: showFiles = true
            }
            #else
            showFiles = true
            #endif
        }
        sync()
    }

    /// The callbacks capture this view, which holds the editor: cleared when it goes away so the web view is freed.
    private func unwire() {
        editor.onChanged = nil
        editor.onLossy = nil
        editor.onOpenLink = nil
        editor.onOpenFile = nil
        editor.onUpload = nil
        editor.onPick = nil
    }

    private func contentTypes(_ accept: String?) -> [UTType] {
        switch accept {
        case "image": [.image]
        case "pdf": [.pdf]
        case "video": [.movie]
        case "audio": [.audio]
        default: [.item]
        }
    }

    private func upload(id: String, file: URL) {
        uploading.insert(id)
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: file) else { return editor.uploadFailed(id: id, message: String(localized: "Could not read “\(file.lastPathComponent)”.")) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        editor.uploadNamed(id: id, name: file.lastPathComponent)
        Task { await send(id: id, name: file.lastPathComponent, mime: mime, data: data) }
    }

    private func send(id: String, name: String, mime: String, data: Data) async {
        defer { uploading.remove(id) }
        do {
            let result = try await session.store.upload(name: name, data: data, contentType: mime.isEmpty ? "application/octet-stream" : mime)
            editor.uploadDone(id: id, src: result.src, name: name.isEmpty ? result.name : name, size: result.size)
            Task { await home.refreshDocs() }
        } catch {
            editor.uploadFailed(id: id, message: error.localizedDescription)
        }
    }

    private func open(src: String, name: String) {
        if src.hasPrefix("http://") || src.hasPrefix("https://"), let url = URL(string: src) {
            onOpenLink(url)
            return
        }
        var path = src.removingPercentEncoding ?? src
        if path.hasPrefix("/") { path.removeFirst() } else if !folder.isEmpty { path = folder + "/" + path }
        path = (path as NSString).standardizingPath
        let loader = mediaLoader
        Task {
            do {
                let data = try await loader.load(DocsPaths.raw(path))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doc-files", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(name.isEmpty ? (path as NSString).lastPathComponent : name)
                try data.write(to: file, options: .atomic)
                preview = file
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

#if os(iOS)
/// The camera, for « Appareil photo » in the editor's toolbar.
struct DocCamera: UIViewControllerRepresentable {
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
#endif
