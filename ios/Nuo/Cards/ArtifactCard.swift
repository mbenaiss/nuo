import QuickLook
import SwiftUI
import WebKit

struct ArtifactCard: View {
    let payload: ArtifactPayload
    @Environment(\.mediaLoader) private var loader
    @State private var file: URL?
    @State private var loading = false
    @State private var failure: String?
    @State private var showsPage = false
    @State private var quickLook: URL?
    @Environment(\.presentPage) private var presentPage

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: payload.symbol)
                .font(.title3)
                .foregroundStyle(Color.accent)
                .frame(width: 40, height: 40)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(2)
                Text(failure ?? payload.error ?? (payload.url == nil ? String(localized: "Preparing the file…") : payload.detail))
                    .font(.caption)
                    .foregroundStyle(payload.error != nil || failure != nil ? Color.red : Color.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.small)
            } else if let file {
                #if os(macOS)
                Button { Task { await save(file) } } label: {
                    Image(systemName: "square.and.arrow.down").font(.body).foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .help("Save…")
                .accessibilityLabel("Save “\(payload.title)”")
                #endif
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up").font(.body).foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share or save “\(payload.title)”")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture { Task { await open() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the file")
        .task(id: payload.url) { await download() }
        .sheet(isPresented: $showsPage) {
            if let file { ArtifactPageView(title: payload.title, file: file) }
        }
        .quickLookPreview($quickLook)
        #if os(macOS)
        .contextMenu {
            if payload.url != nil, payload.error == nil {
                Button("Save…", systemImage: "square.and.arrow.down") {
                    Task {
                        if file == nil { await download() }
                        if let file { await save(file) }
                    }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func save(_ file: URL) async {
        failure = await ArtifactSave.save(file)
    }
    #endif

    private func open() async {
        guard payload.url != nil, payload.error == nil else { return }
        if file == nil { await download() }
        guard let file else { return }
        guard payload.isWebPage else { return quickLook = file }
        if let presentPage { presentPage(.artifact(title: payload.title, file: file)) } else { showsPage = true }
    }

    /// Kept under the media id: the card shows again on every scroll without downloading again.
    private func download() async {
        guard file == nil, !loading, let url = payload.url, payload.error == nil else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent((url as NSString).lastPathComponent, isDirectory: true)
        let target = directory.appendingPathComponent(ArtifactSave.fileName(payload.name))
        if FileManager.default.fileExists(atPath: target.path) {
            file = target
            return
        }
        loading = true
        defer { loading = false }
        do {
            let data = try await loader.load(url)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            file = target
            failure = nil
        } catch {
            failure = String(localized: "Download failed, tap to try again")
        }
    }
}

/// A page opened from a card of the chat. The chat screen shows it, not the card: the card sits in a lazy list that
/// drops it, with any sheet it holds, as soon as the conversation scrolls or moves.
enum FullPage: Identifiable {
    case artifact(title: String, file: URL)
    case diagram(MermaidDiagram)

    var id: String {
        switch self {
        case let .artifact(_, file): file.path
        case let .diagram(diagram): "diagram:\(diagram.svg.hashValue)"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case let .artifact(title, file): ArtifactPageView(title: title, file: file)
        case let .diagram(diagram): MermaidPageView(diagram: diagram)
        }
    }
}

extension EnvironmentValues {
    /// Opens a card's page from the screen that hosts the conversation (see `hostsFullPages`).
    @Entry var presentPage: ((FullPage) -> Void)?
}

private struct FullPageHost: ViewModifier {
    @State private var page: FullPage?

    func body(content: Content) -> some View {
        // Full screen on iPhone: a drag in the page scrolls it and never pulls a sheet down with it.
        #if os(iOS)
        content
            .environment(\.presentPage) { page = $0 }
            .fullScreenCover(item: $page) { $0.view }
        #else
        content
            .environment(\.presentPage) { page = $0 }
            .sheet(item: $page) { $0.view }
        #endif
    }
}

extension View {
    /// Shows the pages that the cards below open, so they stay up however the list under them changes.
    func hostsFullPages() -> some View { modifier(FullPageHost()) }
}

/// A web page or SVG from a bot, full screen, with sharing (which also saves it to Files).
struct ArtifactPageView: View {
    let title: String
    let file: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HTMLWebView(source: .file(file))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 680)
        #endif
    }
}

/// Renders HTML in WebKit. Links leave for the browser: a bot's page never navigates Nuo's web view away.
struct HTMLWebView {
    enum Source: Equatable {
        case file(URL)
        case html(String)
    }

    let source: Source

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        return webView
    }

    private func load(_ webView: WKWebView, _ coordinator: Coordinator) {
        guard coordinator.loaded != source else { return }
        coordinator.loaded = source
        switch source {
        case let .file(url): webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case let .html(html): webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Source?

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url, url.scheme != "about" else { return .allow }
            if url.isFileURL, url.fragment != nil { return .allow }
            #if os(iOS)
            await UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
            return .cancel
        }
    }
}

#if os(iOS)
extension HTMLWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { load(webView, context.coordinator) }
}
#else
extension HTMLWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { load(webView, context.coordinator) }
}
#endif
