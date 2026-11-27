import SwiftUI

/// Block-level Markdown for docs: headings, lists with checkboxes, tables, code, quotes and `> [!NOTE]` callouts,
/// images, rules, `<details>` toggles and `📎`/`🔗` file and link cards (docs/documents.md). Inline styles (bold,
/// italic, code, links, `<span style="color: …">`, `<mark>`, `<u>`) go through `AttributedString(markdown:)`.
indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, text: String)
    case quote(String)
    case callout(kind: String, emoji: String?, blocks: [MarkdownBlock])
    case table(header: [String], rows: [[String]])
    case image(alt: String, source: String, width: Int?)
    case rule
    case toggle(summary: String, blocks: [MarkdownBlock])
    case file(name: String, source: String)
    case bookmark(title: String, url: String)
}

struct MarkdownListItem: Hashable {
    var indent: Int
    var marker: String?
    var checked: Bool?
    var text: String
    /// Line of the item in the source, to toggle its checkbox.
    var line: Int
}

struct MarkdownDocument: Sendable {
    var title: String?
    var tags: [String] = []
    var blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    private final class Box {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    // The reader parsed the whole doc again on every render of its screen (a toggle, the toolbar, an alert).
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 16
        return cache
    }()

    static func parsed(_ source: String) -> MarkdownDocument {
        if let cached = cache.object(forKey: source as NSString) { return cached.document }
        let document = MarkdownDocument(source)
        cache.setObject(Box(document), forKey: source as NSString)
        return document
    }

    init(_ source: String) {
        var lines = source.components(separatedBy: "\n")
        var offset = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "title" { title = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                if parts[0] == "tags" {
                    tags = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'"))) }.filter { !$0.isEmpty }
                }
            }
            offset = end + 1
            lines = Array(lines[(end + 1)...])
        }
        blocks = Self.parse(lines, offset: offset)
    }

    private static func parse(_ lines: [String], offset: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let image = imageMatch(trimmed) ?? imageTag(trimmed) {
                flush()
                blocks.append(.image(alt: image.alt, source: image.source, width: image.width))
                index += 1
                continue
            }
            if paragraph.isEmpty, let card = cardMatch(trimmed), index + 1 >= lines.count || lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(card)
                index += 1
                continue
            }
            if let open = trimmed.range(of: #"^<details(\s+open)?\s*>"#, options: [.regularExpression, .caseInsensitive]),
               let toggle = details(lines, from: index, rest: String(trimmed[open.upperBound...]), offset: offset) {
                flush()
                blocks.append(toggle.block)
                index = toggle.next
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var body = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    quote.append(String(body))
                    index += 1
                }
                if let first = quote.first, first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
                    let kind = first[first.index(first.startIndex, offsetBy: 2)..<close].lowercased()
                    let rest = first[first.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    var body = [rest].filter { !$0.isEmpty } + quote.dropFirst()
                    while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
                    var emoji: String?
                    if let line = body.first, let icon = leadingEmoji(line) {
                        emoji = icon
                        let remainder = String(line.dropFirst(icon.count)).trimmingCharacters(in: .whitespaces)
                        if remainder.isEmpty { body.removeFirst() } else { body[0] = remainder }
                    }
                    // Lines inside a quote carry its "> ": their checkboxes are not toggled from here (negative lines).
                    blocks.append(.callout(kind: kind, emoji: emoji, blocks: parse(body, offset: -1_000_000)))
                } else {
                    blocks.append(.quote(quote.joined(separator: "\n")))
                }
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if listMatch(line) != nil {
                flush()
                var items: [MarkdownListItem] = []
                while index < lines.count, var item = listMatch(lines[index]) {
                    item.line = index + offset
                    items.append(item)
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func imageMatch(_ line: String) -> (alt: String, source: String, width: Int?)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let middle = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<middle.lowerBound])
        let source = String(line[middle.upperBound..<line.index(before: line.endIndex)]).split(separator: " ").first.map(String.init) ?? ""
        return (alt, source.hasPrefix("<") && source.hasSuffix(">") ? String(source.dropFirst().dropLast()) : source, nil)
    }

    /// `<img src="…" alt="…" width="480">`, written by the editor once an image was resized.
    private static func imageTag(_ line: String) -> (alt: String, source: String, width: Int?)? {
        guard line.lowercased().hasPrefix("<img "), line.hasSuffix(">") else { return nil }
        func attribute(_ name: String) -> String? {
            guard let range = line.range(of: #"\b\#(name)\s*=\s*"([^"]*)""#, options: .regularExpression) else { return nil }
            let match = String(line[range])
            guard let open = match.firstIndex(of: "\"") else { return nil }
            return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        }
        guard let source = attribute("src") else { return nil }
        return (attribute("alt") ?? "", source, attribute("width").flatMap { Int($0) })
    }

    /// `[📎 name](path)` (a file, a PDF, a video…) or `[🔗 title](url)` alone on its line.
    private static func cardMatch(_ line: String) -> MarkdownBlock? {
        let file = line.hasPrefix("[📎 ")
        guard file || line.hasPrefix("[🔗 "), line.hasSuffix(")"), let middle = line.range(of: "](", options: .backwards) else { return nil }
        let label = String(line[line.index(line.startIndex, offsetBy: 3)..<middle.lowerBound]).trimmingCharacters(in: .whitespaces)
        var target = String(line[middle.upperBound..<line.index(before: line.endIndex)])
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        return file ? .file(name: label, source: target) : .bookmark(title: label, url: target)
    }

    private static func leadingEmoji(_ line: String) -> String? {
        guard let first = line.first, let scalar = first.unicodeScalars.first, scalar.properties.isEmoji,
              scalar.properties.isEmojiPresentation || first.unicodeScalars.count > 1 else { return nil }
        let rest = line.dropFirst()
        return rest.isEmpty || rest.first == " " ? String(first) : nil
    }

    /// `<details>` … `</details>` with its `<summary>`; nested toggles and fenced code are skipped over.
    private static func details(_ lines: [String], from start: Int, rest: String, offset: Int) -> (block: MarkdownBlock, next: Int)? {
        var index = start + 1
        var summary = rest.trimmingCharacters(in: .whitespaces)
        if summary.isEmpty {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
            guard index < lines.count else { return nil }
            summary = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
        }
        guard let open = summary.range(of: "<summary>", options: .caseInsensitive),
              let close = summary.range(of: "</summary>", options: [.caseInsensitive, .backwards]), open.upperBound <= close.lowerBound else { return nil }
        let title = String(summary[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        var depth = 1
        var fence: String?
        for end in index..<lines.count {
            let line = lines[end].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = fence == nil ? String(line.prefix(3)) : (line.hasPrefix(fence!) ? nil : fence)
                continue
            }
            if fence != nil { continue }
            if line.range(of: #"^<details(\s+open)?\s*>"#, options: [.regularExpression, .caseInsensitive]) != nil { depth += 1 }
            if line.lowercased().hasPrefix("</details>") {
                depth -= 1
                if depth == 0 {
                    return (.toggle(summary: title, blocks: parse(Array(lines[index..<end]), offset: offset + index)), end + 1)
                }
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.allSatisfy { "|-: ".contains($0) } && trimmed.contains("-")
    }

    private static func cells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listMatch(_ line: String) -> MarkdownListItem? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var marker: String?
        var rest: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 4 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            rest = after.dropFirst(2)
        }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") || rest == "[ ]" { checked = false; rest = rest.dropFirst(3) }
        else if rest.lowercased().hasPrefix("[x] ") || rest.lowercased() == "[x]" { checked = true; rest = rest.dropFirst(3) }
        return MarkdownListItem(indent: spaces / 2, marker: marker, checked: checked, text: rest.trimmingCharacters(in: .whitespaces), line: 0)
    }

    /// Flips the checkbox on `line` of `source`.
    static func toggleCheckbox(in source: String, line: Int) -> String {
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return source }
        let current = lines[line]
        if let range = current.range(of: "[ ]") {
            lines[line] = current.replacingCharacters(in: range, with: "[x]")
        } else if let range = current.range(of: "[x]", options: .caseInsensitive) {
            lines[line] = current.replacingCharacters(in: range, with: "[ ]")
        }
        return lines.joined(separator: "\n")
    }
}

private final class InlineMarkdownBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

enum InlineMarkdown {
    // Every block of a doc is parsed again on each render of the reader (a checkbox toggle, the editor's preview).
    nonisolated(unsafe) private static let cache: NSCache<NSString, InlineMarkdownBox> = {
        let cache = NSCache<NSString, InlineMarkdownBox>()
        cache.countLimit = 1024
        return cache
    }()

    static func attributed(_ text: String) -> AttributedString {
        if let cached = cache.object(forKey: text as NSString) { return cached.value }
        let value = parse(text)
        cache.setObject(InlineMarkdownBox(value), forKey: text as NSString)
        return value
    }

    private static func parse(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.allowsExtendedAttributes = true
        let source = html(text)
        var value = (try? AttributedString(markdown: source, including: \.nuo, options: options)) ?? AttributedString(text)
        for run in value.runs {
            if let name = run.nuoColor, let color = NotionPalette.text(name) { value[run.range].foregroundColor = color }
            if let name = run.nuoBackground, let color = NotionPalette.background(name) { value[run.range].backgroundColor = color }
            if run.nuoUnderline == true { value[run.range].underlineStyle = .single }
        }
        for run in value.runs where run.link != nil {
            value[run.range].foregroundColor = Color.accentInk
            value[run.range].underlineStyle = .single
        }
        value = InlineCode.unbreakable(value)
    for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].font = .system(.callout, design: .monospaced)
            value[run.range].backgroundColor = Color.chip
        }
        return value
    }
}

extension InlineMarkdown {
    private static let tags: [(NSRegularExpression, String)] = [
        (#"<span\s+style\s*=\s*["']\s*color\s*:\s*([^"';]+);?\s*["']\s*>((?:(?!<span\b|</span>).)*)</span>"#, "^[$2](nuoColor: '$1')"),
        (#"<span\s+style\s*=\s*["']\s*background(?:-color)?\s*:\s*([^"';]+);?\s*["']\s*>((?:(?!<span\b|</span>).)*)</span>"#, "^[$2](nuoBackground: '$1')"),
        (#"<mark\s+style\s*=\s*["']\s*background(?:-color)?\s*:\s*([^"';]+);?\s*["']\s*>((?:(?!<mark\b|</mark>).)*)</mark>"#, "^[$2](nuoBackground: '$1')"),
        (#"<mark>((?:(?!<mark\b|</mark>).)*)</mark>"#, "^[$1](nuoBackground: 'yellow')"),
        (#"<u>((?:(?!<u>|</u>).)*)</u>"#, "^[$1](nuoUnderline: true)"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive, .dotMatchesLineSeparators]), $0.1) }

    /// The editor's inline HTML (docs/documents.md) as Markdown extended attributes, innermost tags first.
    static func html(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var value = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        for _ in 0..<6 {
            var changed = false
            for (regex, template) in tags {
                let range = NSRange(value.startIndex..., in: value)
                let replaced = regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
                if replaced != value {
                    value = replaced
                    changed = true
                }
            }
            if !changed { break }
        }
        return value
    }
}

enum NuoColorAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = String
    static let name = "nuoColor"
}

enum NuoBackgroundAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = String
    static let name = "nuoBackground"
}

enum NuoUnderlineAttribute: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = Bool
    static let name = "nuoUnderline"
}

extension AttributeScopes {
    struct NuoAttributes: AttributeScope {
        let nuoColor: NuoColorAttribute
        let nuoBackground: NuoBackgroundAttribute
        let nuoUnderline: NuoUnderlineAttribute
        let foundation: FoundationAttributes
        let swiftUI: SwiftUIAttributes
    }

    var nuo: NuoAttributes.Type { NuoAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.NuoAttributes, T>) -> T { self[T.self] }
}

/// Notion's text and background colors (docs/documents.md), the same in the editor.
enum NotionPalette {
    private static let colors: [String: (text: (UInt32, UInt32), background: (UInt32, UInt32))] = [
        "gray": ((0x787774, 0x9B9B9B), (0xF1F1EF, 0x2F2F2F)),
        "brown": ((0x9F6B53, 0xBA856F), (0xF4EEEE, 0x4A3228)),
        "orange": ((0xD9730D, 0xC77D48), (0xFBECDD, 0x5C3B23)),
        "yellow": ((0xCB912F, 0xCA9849), (0xFBF3DB, 0x564328)),
        "green": ((0x448361, 0x529E72), (0xEDF3EC, 0x243D30)),
        "blue": ((0x337EA9, 0x379AD3), (0xE7F3F8, 0x143A4E)),
        "purple": ((0x9065B0, 0x9D68D3), (0xF6F3F9, 0x3C2D49)),
        "pink": ((0xC14C8A, 0xD15796), (0xFAF1F5, 0x4E2C3C)),
        "red": ((0xD44C47, 0xDF5452), (0xFDEBEC, 0x522E2A)),
    ]

    static func text(_ name: String) -> Color? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let pair = colors[key]?.text { return Color.adaptive(light: pair.0, dark: pair.1) }
        return Color(hexString: key)
    }

    static func background(_ name: String) -> Color? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let pair = colors[key]?.background { return Color.adaptive(light: pair.0, dark: pair.1) }
        return Color(hexString: key)?.opacity(0.35)
    }

    /// Callout kinds and their color: GitHub's five alerts plus `info`, Notion's grey default.
    static func callout(_ kind: String) -> (name: String, title: String, symbol: String) {
        switch kind {
        case "info": ("gray", "Info", "lightbulb.fill")
        case "tip": ("green", "Astuce", "lightbulb.fill")
        case "important": ("purple", "Important", "exclamationmark.circle.fill")
        case "warning": ("orange", "Attention", "exclamationmark.triangle.fill")
        case "caution", "danger": ("red", "Danger", "xmark.octagon.fill")
        default: ("blue", "Note", "info.circle.fill")
        }
    }
}

struct MarkdownView: View {
    private static let imageHeight: CGFloat = 200
    let document: MarkdownDocument
    /// Folder of the doc, to resolve relative image paths.
    let basePath: String
    var onToggle: ((Int) -> Void)?

    var body: some View {
        // Lazy: a long doc laid out every block (images and tables included) before showing the first screen.
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                view(block, first: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case let .heading(level, text):
            Text(InlineMarkdown.attributed(text))
                .font(headingFont(level))
                .foregroundStyle(Color.ink)
                .padding(.top, first ? 0 : level <= 2 ? Spacing.md : Spacing.xs)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(InlineMarkdown.attributed(text))
                .font(.body)
                .lineSpacing(TextMetrics.lineSpacing)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: TextMetrics.listItemGap) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in listItem(item) }
            }
        case let .code(language, text):
            if language?.lowercased() == "mermaid" { MermaidCard(code: text) } else { CodeCard(language: language, code: text) }
        case let .quote(text):
            HStack(spacing: Spacing.sm) {
                Capsule().fill(Color.text3.opacity(0.5)).frame(width: TextMetrics.quoteBarWidth)
                Text(InlineMarkdown.attributed(text)).font(.body.italic()).lineSpacing(TextMetrics.lineSpacing).foregroundStyle(Color.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .callout(kind, emoji, blocks):
            callout(kind: kind, emoji: emoji, blocks: blocks)
        case let .table(header, rows):
            DataTable(header: header, rows: rows, render: InlineMarkdown.attributed)
        case let .image(alt, source, width):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                RemoteImage(url: imagePath(source), contentMode: .fill)
                    .frame(maxWidth: width.map { CGFloat($0) } ?? .infinity)
                    .frame(height: Self.imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
                if !alt.isEmpty { Text(alt).font(.caption).foregroundStyle(Color.text2) }
            }
        case let .toggle(summary, blocks):
            DocToggle(summary: summary) { nested(blocks) }
        case let .file(name, source):
            DocFileCard(name: name, source: source, path: repoPath(source))
        case let .bookmark(title, url):
            DocBookmarkCard(title: title, url: url)
        case .rule:
            Divider().overlay(Color.line).padding(.vertical, Spacing.xs)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }

    private func listItem(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            if let checked = item.checked {
                Button {
                    Haptics.selection()
                    onToggle?(item.line)
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(checked ? Color.good : Color.text3)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(onToggle == nil || item.line < 0)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            } else if let marker = item.marker {
                Text(marker).font(.body.monospacedDigit()).foregroundStyle(Color.text2).frame(minWidth: Spacing.lg, alignment: .trailing)
            } else {
                BulletDot(color: .text2)
            }
            Text(InlineMarkdown.attributed(item.text))
                .font(.body)
                .lineSpacing(TextMetrics.lineSpacing)
                .foregroundStyle(item.checked == true ? Color.text3 : Color.ink)
                .strikethrough(item.checked == true, color: Color.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.indent) * TextMetrics.listIndent)
    }

    private func nested(_ blocks: [MarkdownBlock]) -> AnyView {
        AnyView(MarkdownView(document: MarkdownDocument(blocks: blocks), basePath: basePath, onToggle: onToggle))
    }

    private func callout(kind: String, emoji: String?, blocks: [MarkdownBlock]) -> some View {
        let style = NotionPalette.callout(kind)
        let tint = NotionPalette.text(style.name) ?? Color.text2
        return HStack(alignment: .top, spacing: Spacing.sm) {
            if let emoji {
                Text(emoji).font(.title3)
            } else {
                Image(systemName: style.symbol).foregroundStyle(tint).font(.body)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if emoji == nil { Text(style.title).font(.subheadline.weight(.semibold)).foregroundStyle(tint) }
                nested(blocks)
            }
            Spacer(minLength: 0)
        }
        .padding(CardMetrics.padding)
        .background(NotionPalette.background(style.name) ?? Color.chip, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    /// Repo path of a link relative to the doc (nil for a URL).
    private func repoPath(_ source: String) -> String? {
        if source.contains("://") || source.hasPrefix("/api/") { return nil }
        var path = source.removingPercentEncoding ?? source
        if path.hasPrefix("/") { path.removeFirst() } else if !basePath.isEmpty { path = basePath + "/" + path }
        return (path as NSString).standardizingPath
    }

    /// Absolute URLs as is; repository paths through the gateway (relative to the repo root, or to the doc).
    private func imagePath(_ source: String) -> String {
        if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("/api/") { return source }
        var path = source.removingPercentEncoding ?? source
        if path.hasPrefix("/") {
            path.removeFirst()
        } else if !basePath.isEmpty {
            path = basePath + "/" + path
        }
        return DocsPaths.raw((path as NSString).standardizingPath)
    }
}
