import PDFKit
import QuickLook
import SwiftUI

/// `<details>` in the reader: a disclosure row, closed by default like on GitHub.
struct DocToggle<Content: View>: View {
    let summary: String
    @ViewBuilder let content: () -> Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Color.text2)
                    Text(InlineMarkdown.attributed(summary)).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content().padding(.leading, Spacing.lg)
            }
        }
    }
}

/// `[📎 name](path)`: a PDF shows its pages inline, any other file is a card that opens in Quick Look.
struct DocFileCard: View {
    let name: String
    let source: String
    /// Path in the docs repo, nil for a URL.
    let path: String?
    @Environment(\.mediaLoader) private var loader
    @Environment(\.openURL) private var openURL
    @State private var preview: URL?
    @State private var pdf: PDFDocument?
    @State private var loading = false
    @State private var failed = false

    private var ext: String { ((name.contains(".") ? name : source) as NSString).pathExtension.lowercased() }
    private var isPDF: Bool { ext == "pdf" }
    private var isPlayable: Bool { ["mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "ogg", "flac"].contains(ext) }

    private var kind: (label: String, symbol: String) {
        switch ext {
        case "pdf": ("PDF", "doc.richtext")
        case "mp4", "mov", "m4v", "webm": (String(localized: "Video"), "play.rectangle")
        case "mp3", "m4a", "wav", "aac", "ogg", "flac": (String(localized: "Audio"), "waveform")
        case "png", "jpg", "jpeg", "gif", "webp", "heic": (String(localized: "Image"), "photo")
        default: (String(localized: "File"), "paperclip")
        }
    }

    private var size: String? {
        guard let path, let bytes = FilesHomeStore.shared.node(path)?.size, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPDF, let pdf {
                PDFPreview(document: pdf)
                    .frame(height: 420)
                Divider().overlay(Color.line)
            }
            Button(action: open) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: kind.symbol).font(.title3).foregroundStyle(Color.accentInk).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.body.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                        Text([kind.label, size].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.text2)
                    }
                    Spacer(minLength: 0)
                    if loading { ProgressView().controlSize(.small) } else {
                        Text(isPlayable ? String(localized: "Play") : String(localized: "Open"))
                            .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentInk)
                    }
                }
                .padding(CardMetrics.padding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
        .quickLookPreview($preview)
        .task(id: source) {
            guard isPDF, pdf == nil, let path else { return }
            if let data = try? await loader.load(DocsPaths.raw(path)) {
                pdf = PDFDocument(data: data)
            }
        }
    }

    private func open() {
        guard let path else {
            if let url = URL(string: source) { openURL(url) }
            return
        }
        loading = true
        Task {
            defer { loading = false }
            guard let data = try? await loader.load(DocsPaths.raw(path)) else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doc-files", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name.isEmpty ? (path as NSString).lastPathComponent : name)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            preview = file
        }
    }
}

/// `[🔗 title](url)`: a link shown as a card.
struct DocBookmarkCard: View {
    let title: String
    let url: String
    @Environment(\.openURL) private var openURL

    private var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url }

    var body: some View {
        Button {
            if let link = URL(string: url) { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? host : title).font(.body.weight(.medium)).foregroundStyle(Color.ink).lineLimit(2)
                Label(host, systemImage: "link").font(.caption).foregroundStyle(Color.text2).labelStyle(TightLabelStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CardMetrics.padding)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A file of the docs repo that is not text, opened from the files list: a PDF fills the screen, anything else is a
/// card that opens in Quick Look.
struct DocBinaryPage: View {
    let path: String
    let kind: DocFileKind
    @Environment(\.mediaLoader) private var loader
    @State private var pdf: PDFDocument?
    @State private var failure: String?

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        Group {
            if kind != .pdf {
                ScrollView {
                    DocFileCard(name: name, source: name, path: path)
                        .frame(maxWidth: 760)
                        .padding(.horizontal, Spacing.gutter)
                        .padding(.top, Spacing.md)
                }
            } else if let pdf {
                PDFPreview(document: pdf)
            } else if let failure {
                WorkspaceEmptyState(symbol: "doc.questionmark", title: String(localized: "Unreadable PDF"), message: failure)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.canvas)
        .task(id: path) {
            guard kind == .pdf else { return }
            do {
                let data = try await loader.load(DocsPaths.raw(path))
                guard let document = PDFDocument(data: data) else {
                    failure = String(localized: "This file is not a valid PDF.")
                    return
                }
                pdf = document
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

#if os(macOS)
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#else
struct PDFPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif
