import SwiftUI

private final class AttributedBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private enum InlineMarkdownCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = 512
        return cache
    }()
}

enum InlineCode {
    /// Non-breaking spaces inside code spans: a span that wraps would split its chip background across two lines.
    static func unbreakable(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(text[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true, piece.characters.contains(" ") {
                piece = AttributedString(String(piece.characters).replacingOccurrences(of: " ", with: "\u{00A0}"), attributes: run.attributes)
            }
            result.append(piece)
        }
        return result
    }
}

/// `cacheable: false` for text still streaming: every delta is a new string that would push finished ones out.
func inlineMarkdown(_ string: String, cacheable: Bool = true) -> AttributedString {
    let key = string as NSString
    if let cached = InlineMarkdownCache.shared.object(forKey: key) { return cached.value }
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var result = (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    result = InlineCode.unbreakable(result)
    for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
        result[run.range].font = .system(.callout, design: .monospaced)
        result[run.range].backgroundColor = Color.chip
    }
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = Color.accent
    }
    if cacheable { InlineMarkdownCache.shared.setObject(AttributedBox(result), forKey: key) }
    return result
}

/// Loads media served by the gateway (needs the bearer token) or any absolute URL.
struct MediaLoader: Sendable {
    var load: @Sendable (String) async throws -> Data

    static let none = MediaLoader { _ in throw NuoError.notFound }
}

/// Files the user can open from a message: on the Mac, the files of its shared folders that an answer names. The
/// iPhone has none, so the environment leaves it nil there. Equal for the same folder: the chat rebuilds it on every
/// update, and a new value each time would re-render every message.
struct LocalFileLinker: Equatable {
    let preferred: String?
    /// Links each file named in inline code (or as a file link) to its URL.
    let link: @MainActor (AttributedString) -> AttributedString
    /// The files a message names, in order, for its context menu.
    let files: @MainActor (String) -> [URL]
    let reveal: @MainActor (URL) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.preferred == rhs.preferred }
}

extension EnvironmentValues {
    @Entry var localFileLinker: LocalFileLinker?
    /// Set on the last block of an answer still streaming: it grows with every delta.
    @Entry var isStreaming = false
    @Entry var mediaLoader: MediaLoader = .none
    /// Card buttons without a URL send their prompt back to the bot through this.
    @Entry var sendCardPrompt: CardPromptSender?
    /// Whether the message's question cards were answered, and can still be.
    @Entry var questionContext = QuestionContext()
    /// Name of the conversation's bot, for card buttons such as "Enregistrer dans Coach".
    @Entry var cardBotName: String?
    /// Scanning and parcels of the gateway; nil in the demo and before pairing.
    @Entry var scanAPI: (any NuoScanAPI)?
    /// Shows all of a code block or a pasted text the chat laid out in part, by its `TranscriptRows` key.
    @Entry var expandTranscriptPart: TranscriptExpander?
    /// Horizontal offsets of the code blocks the chat cut into rows, so that their slices scroll together.
    @Entry var codeScrollOffsets: CodeScrollOffsets?
}

struct TranscriptExpander: Equatable {
    let expand: @MainActor (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

@MainActor @Observable final class CodeScrollOffsets {
    var offsets: [String: CGFloat] = [:]
}

/// Equatable wrapper so changing the closure does not invalidate every card on each update.
struct CardPromptSender: Equatable {
    let send: @MainActor (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private final class ImageBox {
    let image: PlatformImage
    init(_ image: PlatformImage) { self.image = image }
}

private enum ImageCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 120
        return cache
    }()
}

struct RemoteImage: View {
    let url: String
    var contentMode: ContentMode = .fill
    @Environment(\.mediaLoader) private var loader
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.chip)
                    .overlay {
                        if failed {
                            Image(systemName: "photo").font(.title2).foregroundStyle(Color.text3)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: url) {
            if let cached = ImageCache.shared.object(forKey: url as NSString) {
                image = cached.image
                return
            }
            do {
                let data = try await loader.load(url)
                let decoded = await Task.detached(priority: .userInitiated) { PlatformImage.decoded(data) }.value
                if let decoded {
                    ImageCache.shared.setObject(ImageBox(decoded), forKey: url as NSString)
                    withAnimation(.easeOut(duration: 0.2)) { image = decoded }
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}

struct Kicker: View {
    let text: String
    var symbol: String?
    var tint: Color = .accent

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let symbol { Image(systemName: symbol) }
            Text(text.uppercased())
        }
        .font(.caption2.weight(.bold))
        .tracking(0.9)
        .foregroundStyle(tint)
    }
}

struct ChipButtonLabel: View {
    let title: String
    var symbol: String?
    var prominent = false

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let symbol { Image(systemName: symbol) }
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(prominent ? Color.onInk : Color.ink)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(prominent ? Color.inkFill : Color.chip, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

struct CardActionButton: View {
    let action: CardAction
    var prominent = false
    @Environment(\.sendCardPrompt) private var sendPrompt
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            Haptics.tap()
            if let raw = action.url, let url = URL(string: raw) {
                openURL(url)
            } else {
                sendPrompt?.send(action.prompt ?? action.label)
            }
        } label: {
            ChipButtonLabel(title: action.label, prominent: prominent)
        }
        .buttonStyle(.plain)
    }
}
