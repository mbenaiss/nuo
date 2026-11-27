import SwiftUI

struct BlockView: View {
    let block: ResponseBlock
    @Environment(\.localFileLinker) private var linker
    @Environment(\.isStreaming) private var isStreaming

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(richText(text, linker, cacheable: !isStreaming))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.xxs)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(richText(text, linker, cacheable: !isStreaming))
                .font(.body)
                .lineSpacing(TextMetrics.lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bulletList(items):
            BulletListView(items: items)
        case let .numberedSteps(items):
            StepsView(items: items)
        case let .quote(text):
            HStack(spacing: Spacing.sm) {
                Capsule().fill(Color.accent.opacity(0.6)).frame(width: TextMetrics.quoteBarWidth)
                Text(richText(text, linker, cacheable: !isStreaming)).font(.body).lineSpacing(TextMetrics.lineSpacing).foregroundStyle(Color.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(language, body):
            if language?.lowercased() == "mermaid" { MermaidCard(code: body) } else { CodeCard(language: language, code: body) }
        case let .table(payload):
            TableCard(payload: payload)
        case .divider:
            Divider().overlay(Color.line).padding(.vertical, Spacing.xxs)
        case let .callout(payload):
            CalloutCard(payload: payload)
        case let .facts(payload):
            FactsCard(payload: payload)
        case let .event(payload):
            EventCard(payload: payload)
        case let .carousel(blocks):
            CarouselView(blocks: blocks)
        case let .place(payload):
            PlaceCard(payload: payload)
        case let .contact(payload):
            ContactCard(payload: payload)
        case let .weather(payload):
            WeatherCard(payload: payload)
        case let .stock(payload):
            StockCard(payload: payload)
        case let .route(payload):
            RouteCard(payload: payload)
        case let .media(payload):
            MediaCard(payload: payload)
        case let .metrics(payload):
            MetricsCard(payload: payload)
        case let .chart(payload):
            ChartCard(payload: payload)
        case let .nowPlaying(payload):
            NowPlayingCard(payload: payload)
        case let .photos(payload):
            PhotosCard(payload: payload)
        case let .image(payload):
            ImageCard(payload: payload)
        case let .flight(payload):
            FlightCard(payload: payload)
        case let .product(payload):
            ProductCard(payload: payload)
        case let .cosmetic(payload):
            CosmeticCard(payload: payload)
        case let .parcel(payload):
            ParcelCard(payload: payload)
        case let .notice(payload):
            NoticeChip(payload: payload)
        case let .artifact(payload):
            ArtifactCard(payload: payload)
        case let .conversation(payload):
            ConversationLinkCard(payload: payload)
        case let .questions(questions):
            QuestionCard(questions: questions)
        }
    }
}

struct BulletListView: View {
    let items: [String]
    @Environment(\.localFileLinker) private var linker
    @Environment(\.isStreaming) private var isStreaming

    var body: some View {
        VStack(alignment: .leading, spacing: TextMetrics.listItemGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    BulletDot()
                    Text(richText(item, linker, cacheable: !isStreaming)).lineSpacing(TextMetrics.lineSpacing).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bullet of a prose list, centred on the x-height of the first line.
struct BulletDot: View {
    var color: Color = .text3
    @ScaledMetric(relativeTo: .body) private var lift = TextMetrics.bulletLift

    var body: some View {
        Circle().fill(color)
            .frame(width: TextMetrics.bulletSize, height: TextMetrics.bulletSize)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
            .frame(width: Spacing.sm)
    }
}

struct StepsView: View {
    let items: [String]
    /// Number of the first item: a long list the chat cut into rows carries on its numbering.
    var start = 1
    @Environment(\.localFileLinker) private var linker
    @Environment(\.isStreaming) private var isStreaming

    var body: some View {
        VStack(alignment: .leading, spacing: TextMetrics.listItemGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text("\(index + start).")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.text2)
                        .frame(minWidth: Spacing.sm, alignment: .trailing)
                    Text(richText(item, linker, cacheable: !isStreaming)).lineSpacing(TextMetrics.lineSpacing).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A long block is laid out in part: while it streams, its last lines (a full layout on every delta stalls the window),
/// once done, its first lines until the user asks for all. Copying always takes the whole code.
struct CodeCard: View {
    let language: String?
    let code: String
    /// The part of the block a chat row shows, which the chat chose; without it the card shortens itself.
    var slice: CodeSlice?
    @Environment(\.isStreaming) private var isStreaming
    @State private var copied = false
    @State private var expanded = false

    static let streamingLines = 120
    static let collapsedLines = 300

    var body: some View {
        if let slice {
            CodeSliceCard(slice: slice) { header }
        } else {
            whole
        }
    }

    private var header: some View {
        HStack {
            Text(language ?? "code").font(.caption.weight(.medium)).foregroundStyle(Color.text2)
            Spacer()
            Button {
                PlatformPasteboard.copy(code)
                Haptics.success()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
    }

    private var whole: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.line)
            let shown = excerpt
            if isStreaming, shown.hidden > 0 {
                Text("… \(shown.hidden) lines above")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.text3)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.xs)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown.text)
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(TextMetrics.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(Spacing.sm)
            }
            if !isStreaming, shown.hidden > 0 {
                Divider().overlay(Color.line)
                Button {
                    expanded = true
                } label: {
                    Label("Show all \(Self.collapsedLines + shown.hidden) lines", systemImage: "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
    }

    private var excerpt: TextExcerpt.Lines {
        if isStreaming { return TextExcerpt.lastLines(code, Self.streamingLines) }
        if expanded { return TextExcerpt.Lines(text: code[...], hidden: 0) }
        return TextExcerpt.firstLines(code, Self.collapsedLines)
    }
}

/// A row's part of a code block: the card's top on its first slice, its bottom on its last, one surface across them.
private struct CodeSliceCard<Header: View>: View {
    let slice: CodeSlice
    @ViewBuilder let header: Header
    @Environment(\.expandTranscriptPart) private var expand

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if slice.isFirst {
                header
                Divider().overlay(Color.line)
            }
            if slice.hiddenAbove > 0 {
                Text("… \(slice.hiddenAbove) lines above")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.text3)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.xs)
            }
            CodeSliceText(slice: slice)
            if slice.hiddenBelow > 0 {
                Divider().overlay(Color.line)
                Button {
                    expand?.expand(slice.key)
                } label: {
                    Label("Show all \(TextExcerpt.lineCount(slice.text) + slice.hiddenBelow) lines", systemImage: "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chip.opacity(0.6), in: CardSlice(top: slice.isFirst, bottom: slice.isLast))
        .overlay(CardSlice(top: slice.isFirst, bottom: slice.isLast, outline: true).strokeBorder(Color.line, lineWidth: 1))
    }
}

/// The lines of a code slice.
private struct CodeSliceText: View {
    let slice: CodeSlice

    var body: some View {
        SlicesHorizontalScroll(key: slice.key) {
            Text(slice.text)
                .font(.system(.footnote, design: .monospaced))
                .lineSpacing(TextMetrics.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, Spacing.sm)
                .padding(.top, slice.isFirst ? Spacing.sm : 0)
                // Inside a slice, lines are this far apart; the next slice starts flush under it.
                .padding(.bottom, slice.isLast ? Spacing.sm : TextMetrics.lineSpacing)
        }
    }
}

/// A slice of a block the chat cut into rows, scrolling sideways together with the other slices of the block under
/// `key`: the one the reader moves sets the offset.
struct SlicesHorizontalScroll<Content: View>: View {
    let key: String
    @ViewBuilder let content: Content
    @Environment(\.codeScrollOffsets) private var offsets
    @State private var position = ScrollPosition(edge: .leading)
    @State private var moving = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { content }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in moving = phase == .tracking || phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                if moving { offsets?.offsets[key] = x }
            }
            .onChange(of: offsets?.offsets[key]) { _, x in
                if !moving, let x { position.scrollTo(x: x) }
            }
            .onAppear {
                if let x = offsets?.offsets[key] { position.scrollTo(x: x) }
            }
    }
}

/// A row's lines of a quote: its bar is rounded only where the quote starts or ends, and runs on into the next slice,
/// which sits flush under this one.
struct QuoteSliceView: View {
    let slice: QuoteSlice
    @Environment(\.localFileLinker) private var linker
    @Environment(\.isStreaming) private var isStreaming

    var body: some View {
        HStack(spacing: Spacing.sm) {
            bar
            Text(richText(slice.text, linker, cacheable: !isStreaming)).font(.body).lineSpacing(TextMetrics.lineSpacing).foregroundStyle(Color.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, slice.isLast ? 0 : TextMetrics.lineSpacing)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bar: some View {
        let top = slice.isFirst ? TextMetrics.quoteBarWidth / 2 : 0
        let bottom = slice.isLast ? TextMetrics.quoteBarWidth / 2 : 0
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
            .fill(Color.accent.opacity(0.6))
            .frame(width: TextMetrics.quoteBarWidth)
    }
}

/// A card's surface cut across rows: rounded corners only where the card starts or ends, and with `outline`, no edge
/// where a slice meets the next one.
struct CardSlice: InsettableShape {
    let top: Bool
    let bottom: Bool
    var outline = false
    var radius = Radius.md
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let topRadius = top ? max(0, radius - inset) : 0
        let bottomRadius = bottom ? max(0, radius - inset) : 0
        guard outline else {
            return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
                topLeading: topRadius, bottomLeading: bottomRadius, bottomTrailing: bottomRadius, topTrailing: topRadius))
        }
        var path = Path()
        // The sides of an open edge run to the frame's edge, where the next slice's sides carry on.
        let minY = top ? rect.minY : rect.minY - inset
        let maxY = bottom ? rect.maxY : rect.maxY + inset
        path.move(to: CGPoint(x: rect.minX, y: maxY - bottomRadius))
        path.addLine(to: CGPoint(x: rect.minX, y: minY + topRadius))
        if top {
            path.addArc(center: CGPoint(x: rect.minX + topRadius, y: minY + topRadius), radius: topRadius,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: minY))
            path.addArc(center: CGPoint(x: rect.maxX - topRadius, y: minY + topRadius), radius: topRadius,
                        startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: maxY - bottomRadius))
        if bottom {
            path.addArc(center: CGPoint(x: rect.maxX - bottomRadius, y: maxY - bottomRadius), radius: bottomRadius,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: maxY))
            path.addArc(center: CGPoint(x: rect.minX + bottomRadius, y: maxY - bottomRadius), radius: bottomRadius,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        return path
    }

    func inset(by amount: CGFloat) -> CardSlice {
        var shape = self
        shape.inset += amount
        return shape
    }
}

struct TableCard: View {
    let payload: TablePayload

    var body: some View {
        DataTable(header: payload.header, rows: payload.rows) { inlineMarkdown($0) }
    }
}

/// Markdown table: fills the width when it fits, scrolls sideways otherwise, with the header and separators
/// running edge to edge either way.
struct DataTable: View {
    let header: [String]
    let rows: [[String]]
    let render: (String) -> AttributedString

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(stretch: true)
            ScrollView(.horizontal, showsIndicators: false) { grid(stretch: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
    }

    private func grid(stretch: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column], stretch: stretch && column == header.count - 1).font(.footnote.weight(.semibold)).foregroundStyle(Color.text2)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(Color.line).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(column < row.count ? row[column] : "", stretch: stretch && column == header.count - 1).font(.subheadline).foregroundStyle(Color.ink)
                    }
                }
            }
        }
        .fixedSize(horizontal: !stretch, vertical: false)
    }

    /// Columns keep their natural width; in the fitting variant the last one takes the remaining space.
    private func cell(_ text: String, stretch: Bool) -> some View {
        Text(render(text))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: stretch ? .infinity : nil, alignment: .leading)
    }
}

extension CalloutStyle {
    var tint: Color {
        switch self {
        case .info: Color(hex: 0x3B82F6)
        case .success: Color(hex: 0x16A34A)
        case .warning: Color(hex: 0xF97316)
        case .tip: Color(hex: 0xF59E0B)
        case .error: Color(hex: 0xE5484D)
        }
    }
}

struct CalloutCard: View {
    let payload: CalloutPayload

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: payload.style.symbol).font(.body).foregroundStyle(payload.style.tint)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(payload.title ?? payload.style.label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Text(inlineMarkdown(payload.text)).font(.subheadline).foregroundStyle(Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CardMetrics.padding)
        .background(payload.style.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(payload.style.tint.opacity(0.22), lineWidth: 1))
    }
}

struct FactsCard: View {
    let payload: FactsPayload

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let title = payload.title { Kicker(text: title) }
            VStack(spacing: 0) {
                ForEach(Array(payload.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text(item.key).font(.subheadline).foregroundStyle(Color.text2)
                        Spacer(minLength: Spacing.sm)
                        Text(inlineMarkdown(item.value)).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, Spacing.xs)
                    if index < payload.items.count - 1 { Divider().overlay(Color.line) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MetricsCard: View {
    let payload: MetricsPayload
    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            if let title = payload.title { Kicker(text: title, symbol: payload.symbol) }
            DashboardGrid(minColumnWidth: DashboardMetrics.tileMinWidth / 2, maxColumns: 2, spacing: Spacing.xs) {
                ForEach(Array(payload.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(item.label).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                        Text(item.value).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                    .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Renders a list of same-kind cards as a horizontally snapping carousel.
struct CarouselView: View {
    let blocks: [ResponseBlock]

    var body: some View {
        if blocks.count <= 1, let only = blocks.first {
            BlockView(block: only)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        BlockView(block: block).frame(width: CardMetrics.carouselWidth)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }
}

@MainActor
func richText(_ text: String, _ linker: LocalFileLinker?, cacheable: Bool = true) -> AttributedString {
    let base = inlineMarkdown(text, cacheable: cacheable)
    return linker?.link(base) ?? base
}
