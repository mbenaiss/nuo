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
    /// The `::email` card's drafts; nil before pairing, when the card stays read only.
    @Entry var emailDraftAPI: (any NuoEmailDraftAPI)?
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

extension CardQuantity {
    /// The bot's text, or the number in the user's locale.
    func value(maxFraction: Int = 1) -> String {
        if let text { return text }
        guard let number else { return "" }
        return number.formatted(.number.precision(.fractionLength(0...maxFraction)))
    }

    /// Value and unit as one string, for a line of text.
    func line(maxFraction: Int = 1) -> String {
        guard let unit else { return value(maxFraction: maxFraction) }
        return unit.hasPrefix("°") || unit == "%" ? value(maxFraction: maxFraction) + unit : "\(value(maxFraction: maxFraction)) \(unit)"
    }
}

/// Icon tile, title and subtitle at the top of a card, with an optional trailing badge or figure.
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Color.ink).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Color.text2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String?) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A figure inside a card: label, value and a smaller unit, on the canvas color.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xxs) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(label).font(.caption2).foregroundStyle(Color.text2).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.headline.monospacedDigit()).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.caption2.weight(.medium)).foregroundStyle(Color.text2).lineLimit(1).fixedSize() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension StatTile {
    init(label: String, quantity: CardQuantity, maxFraction: Int = 1, dot: Color? = nil) {
        self.init(label: label, value: quantity.value(maxFraction: maxFraction), unit: quantity.text == nil ? quantity.unit : nil, dot: dot)
    }
}

/// The bot's short comment at the bottom of a card.
struct CardNote: View {
    let text: String
    var symbol = "text.bubble.fill"
    var tint: Color = .accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(tint)
            Text(inlineMarkdown(text)).font(.subheadline).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
    }
}

enum CardDate {
    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "Today", "Sat, Nov 28" or "Sat, Nov 28, 7:12 AM" from an ISO date; any other text as written.
    static func label(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.count > 10, let date = NuoJSON.parseDate(value) {
            let time = date.formatted(date: .omitted, time: .shortened)
            return Calendar.current.isDateInToday(date) ? "\(String(localized: "Today")), \(time)" : "\(day(date)), \(time)"
        }
        guard value.count == 10, let date = dayParser.date(from: value) else { return value }
        return Calendar.current.isDateInToday(date) ? String(localized: "Today") : day(date)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.current))
    }
}

/// Tiles of a card in as many columns of at least `minimum` as fit, spread over balanced rows (7 tiles in 4 + 3,
/// not 6 + 1), left aligned, each row as tall as its tallest tile.
struct TileGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = Spacing.xs

    private func columns(width: CGFloat, count: Int) -> Int {
        let fit = max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
        let rows = Int((Double(count) / Double(min(fit, count))).rounded(.up))
        return max(1, Int((Double(count) / Double(rows)).rounded(.up)))
    }

    private func rows(width: CGFloat, subviews: Subviews) -> (itemWidth: CGFloat, columns: Int, heights: [CGFloat]) {
        let columns = columns(width: width, count: subviews.count)
        let itemWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
        }
        return (itemWidth, columns, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimum
        let layout = rows(width: width, subviews: subviews)
        return CGSize(width: width, height: layout.heights.reduce(0, +) + spacing * CGFloat(max(layout.heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.itemWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: layout.itemWidth, height: height))
            }
            y += height + spacing
        }
    }
}
