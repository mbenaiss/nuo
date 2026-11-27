import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The visual document editor: a ProseMirror page bundled in the app (Resources/DocEditor, built from ios/DocEditor)
/// and loaded offline through the `nuo-editor` scheme. Markdown goes in and comes out; the page never sees the network:
/// repo images and PDF previews are fetched by the app with the gateway token.
@MainActor @Observable
final class RichDocEditor: NSObject {
    struct Format: Equatable {
        var bold = false, italic = false, underline = false, strike = false, code = false, link = false
        var block = "text"
        var canUndo = false, canRedo = false
        var selection = false
    }

    private(set) var ready = false
    /// A document is shown (first frame drawn after `load`).
    private(set) var loaded = false
    private(set) var focused = false
    private(set) var format = Format()

    @ObservationIgnored let webView: WKWebView
    /// The user changed the document; its Markdown is read with `markdown()` when saving.
    @ObservationIgnored var onChanged: (() -> Void)?
    @ObservationIgnored var onLossy: (() -> Void)?
    @ObservationIgnored var onOpenLink: ((String) -> Void)?
    @ObservationIgnored var onOpenFile: ((_ src: String, _ name: String) -> Void)?
    @ObservationIgnored var onUpload: ((_ id: String, _ name: String, _ mime: String, _ data: Data) -> Void)?
    @ObservationIgnored var onPick: ((_ id: String, _ accept: String) -> Void)?
    /// Bytes of a file of the docs repo.
    @ObservationIgnored var loader: (@Sendable (String) async throws -> Data)?
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private let schemeHandler = EditorSchemeHandler()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EditorSchemeHandler.scheme)
        configuration.userContentController = WKUserContentController()
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        schemeHandler.editor = self
        configuration.userContentController.add(MessageProxy(self), name: "nuo")
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.keyboardDismissMode = .interactive
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: URL(string: "\(EditorSchemeHandler.scheme)://app/doc-editor.html")!))
    }

    deinit {
        MainActor.assumeIsolated {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "nuo")
        }
    }

    // MARK: Calls into the page

    func load(markdown: String, basePath: String, sizes: [String: Int], docs: [String], dark: Bool, focus: Bool) {
        let platform: String
        #if os(macOS)
        platform = "mac"
        #else
        platform = "ios"
        #endif
        call("nuo.load", [
            "markdown": markdown, "basePath": basePath, "platform": platform, "theme": dark ? "dark" : "light",
            "sizes": sizes, "docs": docs, "focus": focus,
        ])
    }

    func setMarkdown(_ markdown: String) { call("nuo.setMarkdown", markdown) }

    func setTheme(dark: Bool) { call("nuo.setTheme", dark ? "dark" : "light") }
    func setFiles(sizes: [String: Int], docs: [String]) { call("nuo.setFiles", sizes, docs) }
    func command(_ name: String, _ argument: String? = nil) { call("nuo.command", name, argument ?? "") }
    func uploadDone(id: String, src: String, name: String, size: Int) { call("nuo.uploadDone", id, ["src": src, "name": name, "size": size]) }
    func uploadFailed(id: String, message: String) { call("nuo.uploadFailed", id, message) }
    func uploadNamed(id: String, name: String) { call("nuo.uploadNamed", id, name) }

    func focus() {
        #if os(macOS)
        webView.window?.makeFirstResponder(webView)
        #endif
        call("nuo.focus")
    }

    func blur() {
        #if os(iOS)
        webView.endEditing(true)
        #endif
        call("nuo.blur")
    }

    /// Current Markdown, without waiting for the page's debounced change event.
    func markdown() async -> String? {
        guard ready else { return nil }
        return try? await webView.evaluateJavaScript("nuo.markdown()") as? String
    }

    private func call(_ function: String, _ arguments: Any...) {
        let encoded = arguments.map { argument -> String in
            guard let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }
        let script = "\(function)(\(encoded.joined(separator: ",")))"
        if ready { webView.evaluateJavaScript(script) } else { queued.append(script) }
    }

    // MARK: Messages from the page

    fileprivate func receive(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            ready = true
            let scripts = queued
            queued = []
            for script in scripts { webView.evaluateJavaScript(script) }
        case "changed":
            onChanged?()
        case "loaded":
            loaded = true
        case "lossy":
            onLossy?()
        case "openLink":
            if let href = body["href"] as? String { onOpenLink?(href) }
        case "openFile":
            if let src = body["src"] as? String { onOpenFile?(src, body["name"] as? String ?? "") }
        case "upload":
            guard let id = body["id"] as? String, let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else { return }
            onUpload?(id, body["name"] as? String ?? "fichier", body["mime"] as? String ?? "", data)
        case "pick":
            if let id = body["id"] as? String { onPick?(id, body["accept"] as? String ?? "file") }
        case "state":
            format = Format(
                bold: body["bold"] as? Bool ?? false, italic: body["italic"] as? Bool ?? false,
                underline: body["underline"] as? Bool ?? false, strike: body["strike"] as? Bool ?? false,
                code: body["code"] as? Bool ?? false, link: body["link"] as? Bool ?? false,
                block: body["block"] as? String ?? "text",
                canUndo: body["canUndo"] as? Bool ?? false, canRedo: body["canRedo"] as? Bool ?? false,
                selection: body["selection"] as? Bool ?? false)
        case "focus":
            focused = true
        case "blur":
            focused = false
        default:
            break
        }
    }

    fileprivate func load(asset path: String) async throws -> Data {
        guard let loader else { throw NuoError.notFound }
        return try await loader(path)
    }
}

extension RichDocEditor {
    private static var spare: RichDocEditor?

    /// Starts a web view with the editor page in the background, so the next document opens without the page load.
    static func prewarm() {
        if spare == nil { spare = RichDocEditor() }
    }

    /// The warmed editor if there is one; a new spare is warmed shortly after.
    static func make() -> RichDocEditor {
        let editor = spare ?? RichDocEditor()
        spare = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            prewarm()
        }
        return editor
    }
}

/// WKUserContentController keeps its handlers alive; going through a weak proxy lets the editor go away.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var editor: RichDocEditor?
    init(_ editor: RichDocEditor) { self.editor = editor }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { editor?.receive(body) }
    }
}

/// Serves the bundled page, the repo's files (`/asset?path=`) and the first page of PDFs (`/thumb?path=`).
private final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nuo-editor"
    weak var editor: RichDocEditor?
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        switch url.path {
        case "/asset", "/thumb":
            guard let path else { return fail(task, status: 400) }
            let thumbnail = url.path == "/thumb"
            Task { @MainActor in
                do {
                    guard let editor else { throw NuoError.notFound }
                    let data = try await editor.load(asset: path)
                    if thumbnail {
                        guard let png = await Task.detached(priority: .userInitiated, operation: { Self.pdfThumbnail(data) }).value else { throw NuoError.notFound }
                        respond(task, data: png, mime: "image/png")
                    } else {
                        respond(task, data: data, mime: UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                    }
                } catch {
                    fail(task, status: 404)
                }
            }
        default:
            let name = (url.path as NSString).lastPathComponent
            guard let file = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension),
                  let data = try? Data(contentsOf: file) else { return fail(task, status: 404) }
            let mime = switch (name as NSString).pathExtension {
            case "html": "text/html"
            case "js": "text/javascript"
            case "css": "text/css"
            default: "application/octet-stream"
            }
            respond(task, data: data, mime: mime)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: any WKURLSchemeTask, data: Data, mime: String) {
        guard !stopped.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, status: Int) {
        guard !stopped.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        task.didFinish()
    }

    nonisolated static func pdfThumbnail(_ data: Data) -> Data? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2, 1400 / max(bounds.width, 1))
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }
}

#if os(macOS)
struct RichDocEditorView: NSViewRepresentable {
    let editor: RichDocEditor
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        editor.setTheme(dark: colorScheme == .dark)
        return editor.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        editor.setTheme(dark: colorScheme == .dark)
    }
}
#else
struct RichDocEditorView: UIViewRepresentable {
    let editor: RichDocEditor
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        editor.setTheme(dark: colorScheme == .dark)
        return editor.webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        editor.setTheme(dark: colorScheme == .dark)
    }
}
#endif
