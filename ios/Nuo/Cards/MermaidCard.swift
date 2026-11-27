import SwiftUI

/// A ```mermaid block of an answer or a doc, drawn as a diagram; its code stays one tap away.
struct MermaidCard: View {
    let code: String
    /// The part of the code a chat row shows when the diagram cannot be drawn; the chat also keeps the drawing under a
    /// row's height. Without it the card shows all of it.
    var slice: CodeSlice?
    @State private var result: Result<MermaidDiagram, MermaidError>?
    @State private var showsCode = false
    @State private var expanded = false
    @State private var cropped = false
    @State private var width: Double = 0
    @Environment(\.presentPage) private var presentPage

    var body: some View {
        Group {
            switch result {
            case nil where width == 0:
                Color.clear.frame(height: 120)
            case nil:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case let .failure(error):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    CodeCard(language: "mermaid", code: code, slice: slice)
                    Label(error.label, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.text2)
                }
            case let .success(diagram):
                if showsCode {
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        CodeCard(language: "mermaid", code: code, slice: slice)
                        toggle
                    }
                } else {
                    card(diagram)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Steps of 40 pt: a resize redraws the diagram only when it changes its layout.
        .onGeometryChange(for: Double.self) { (($0.size.width - 2 * Spacing.sm) / 40).rounded(.down) * 40 } action: { width = $0 }
        // While an answer streams, the block changes on every token: draw it once it settles.
        .task(id: "\(Int(width))\n\(code)") {
            guard width > 0 else { return }
            try? await Task.sleep(for: .milliseconds(result == nil ? 0 : 250))
            guard !Task.isCancelled else { return }
            let source = code, maxWidth = width
            result = await Task.detached(priority: .userInitiated) { MermaidRenderer.shared.render(source, maxWidth: maxWidth) }.value
        }
    }

    private var toggle: some View {
        Button(showsCode ? String(localized: "Diagram") : String(localized: "Code")) { showsCode.toggle() }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.text2)
            .buttonStyle(.plain)
    }

    /// In a chat row, a diagram taller than a row keeps its width and shows its top: drawn whole it would be too
    /// narrow to read. A tap opens all of it.
    private func drawing(_ diagram: MermaidDiagram) -> some View {
        let limit: CGFloat? = slice == nil ? nil : TranscriptLimits.diagramHeight
        return HTMLWebView(source: .html(MermaidPage.html(diagram, zoomable: false)))
            .allowsHitTesting(false)
            .aspectRatio(diagram.width / diagram.height, contentMode: .fit)
            .frame(maxWidth: diagram.width)
            .fixedSize(horizontal: false, vertical: limit != nil)
            .onGeometryChange(for: Bool.self) { proxy in limit.map { proxy.size.height > $0 + 0.5 } ?? false } action: { cropped = $0 }
            .frame(maxHeight: limit, alignment: .top)
            .mask(LinearGradient(stops: [.init(color: .black, location: cropped ? 0.82 : 1), .init(color: cropped ? .clear : .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }

    private func card(_ diagram: MermaidDiagram) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.text2)
                Spacer()
                toggle
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            Divider().overlay(Color.line)
            // Taps and scrolls go to the card and the page around it, not to the web view.
            drawing(diagram)
                .frame(maxWidth: .infinity)
                .padding(Spacing.sm)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let presentPage { presentPage(.diagram(diagram)) } else { expanded = true }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Diagram")
                .accessibilityHint("Opens the diagram full size")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
        .sheet(isPresented: $expanded) { MermaidPageView(diagram: diagram) }
    }
}

/// Full screen, pinch to zoom.
struct MermaidPageView: View {
    let diagram: MermaidDiagram
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HTMLWebView(source: .html(MermaidPage.html(diagram, zoomable: true)))
                .background(Color.card)
                .navigationTitle("Diagram")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
}

enum MermaidPage {
    /// Pele colors through CSS variables: the app's palette, light and dark, follows the system appearance live. The
    /// background is the card's, not transparent: Pele writes the labels inside filled shapes (gantt bars) in it.
    static func html(_ diagram: MermaidDiagram, zoomable: Bool) -> String {
        let viewport = zoomable ? "width=device-width, initial-scale=1, maximum-scale=6" : "width=device-width, initial-scale=1, maximum-scale=1"
        let layout = zoomable
            ? "body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box}svg{max-width:100%;height:auto}"
            : "svg{display:block;width:100%;height:auto}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="\(viewport)">
        <style>
        :root{color-scheme:light dark}
        html,body{margin:0;background:transparent}
        \(layout)
        .pele{--pele-bg:#FFFFFF;--pele-fg:#16161A;--pele-muted:#6E6C72;--pele-line:#6E6C72;--pele-surface:#F6F4F0;--pele-surface-alt:#EFECE6;--pele-border:#D9D5CE;--pele-accent:#FF6A2B;--pele-font:-apple-system,sans-serif;--pele-radius:8px}
        @media (prefers-color-scheme:dark){.pele{--pele-bg:#18181D;--pele-fg:#F4F2EE;--pele-muted:#9C9AA2;--pele-line:#9C9AA2;--pele-surface:#232329;--pele-surface-alt:#2C2C33;--pele-border:#3A3A42}}
        </style></head><body>\(diagram.svg)</body></html>
        """
    }
}
