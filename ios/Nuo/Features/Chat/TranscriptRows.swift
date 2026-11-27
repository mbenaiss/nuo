import CoreGraphics
import Foundation

/// A lazy stack scrolled to its end over rows several screens tall settles on estimated heights its rows never match:
/// the chat opened on an empty area or mid-answer, and no programmatic scroll put it right until the reader dragged.
/// With rows about a screen tall it lands on its end, so the transcript lays each message out in such rows.
enum TranscriptLimits {
    /// Estimated height a row stays under. On an iPhone 17 Pro, rows up to 890 pt tall opened on their end every time and
    /// rows from 926 pt did not; rows of this estimate measure at most 556 pt, which leaves room for a short estimate.
    static let rowHeight: CGFloat = 560
    /// Lines of a finished code block shown until the reader asks for all of them.
    static let codeCollapsedLines = 20
    /// Last lines of a code block shown while it streams.
    static let codeStreamingLines = 30
    /// Start of a pasted text shown until the reader asks for all of it.
    static let pastedPreviewCharacters = 600
    static let pastedPreviewLines = 20
    /// Height a diagram drawn in the chat stays under, so that its card fits in a row.
    static let diagramHeight: CGFloat = 400
}

/// Heights of transcript content at the default text size across an iPhone's width, a little high so that a row does
/// not outgrow its estimate.
struct TranscriptMetrics: Equatable {
    var proseCharactersPerLine = 38
    var proseLine: CGFloat = 24
    var bubbleCharactersPerLine = 30
    var bubbleLine: CGFloat = 22
    var codeLine: CGFloat = 18.5
    /// Header, divider and padding of a code card; its footer button adds `codeFooter`.
    var codeChrome: CGFloat = 60
    var codeFooter: CGFloat = 36
    var blockGap: CGFloat = 10
    var heading: CGFloat = 36
    var divider: CGFloat = 20
    var tableHeader: CGFloat = 44
    var tableRow: CGFloat = 44
    var card: CGFloat = 340
    var workRow: CGFloat = 44
    var footer: CGFloat = 34
    var image: CGFloat = 210
    var fileChip: CGFloat = 52
    var bubblePadding: CGFloat = 20
    var expandButton: CGFloat = 26
    /// The error or the toggle under a diagram's code.
    var diagramNote: CGFloat = 28

    /// Lines of a short excerpt at this text size: `lines` at the default one, fewer as `line` grows past
    /// `defaultLine`, so that the excerpt keeps its height and its row stays under a screen.
    static func excerptLines(_ lines: Int, line: CGFloat, defaultLine: CGFloat) -> Int {
        guard line > defaultLine else { return lines }
        return max(3, Int(CGFloat(lines) * defaultLine / line))
    }

    var codeCollapsedLines: Int {
        Self.excerptLines(TranscriptLimits.codeCollapsedLines, line: codeLine, defaultLine: TranscriptMetrics().codeLine)
    }

    var codeStreamingLines: Int {
        Self.excerptLines(TranscriptLimits.codeStreamingLines, line: codeLine, defaultLine: TranscriptMetrics().codeLine)
    }

    var pastedPreviewLines: Int {
        Self.excerptLines(TranscriptLimits.pastedPreviewLines, line: bubbleLine, defaultLine: TranscriptMetrics().bubbleLine)
    }

    /// Larger text sizes make lines taller and hold fewer characters.
    func scaled(by factor: CGFloat) -> TranscriptMetrics {
        guard factor > 1 else { return self }
        var metrics = self
        metrics.proseCharactersPerLine = max(8, Int(CGFloat(proseCharactersPerLine) / factor))
        metrics.bubbleCharactersPerLine = max(8, Int(CGFloat(bubbleCharactersPerLine) / factor))
        metrics.proseLine *= factor
        metrics.bubbleLine *= factor
        metrics.codeLine *= factor
        metrics.heading *= factor
        metrics.tableRow *= factor
        metrics.tableHeader *= factor
        return metrics
    }
}

/// The gap above a row: between messages, between the blocks of an answer, or inside a block cut in two, where the row
/// carries on the line, the list or the card of the row above.
enum TranscriptJoint: Equatable {
    case start
    case message
    case block
    case line
    case listItem
    case flush
}

/// Part of a code block in a row: its first lines while collapsed, its last lines while it streams, or a slice of it once
/// the reader asked for all of it.
struct CodeSlice: Equatable {
    let key: String
    let language: String?
    /// The whole code, for copying.
    let code: String
    let text: Substring
    let hiddenAbove: Int
    /// Lines left out under a collapsed block, which its button shows.
    let hiddenBelow: Int
    let isFirst: Bool
    let isLast: Bool

    static func == (lhs: CodeSlice, rhs: CodeSlice) -> Bool {
        lhs.key == rhs.key && lhs.language == rhs.language && lhs.code.utf8.count == rhs.code.utf8.count
            && lhs.text.startIndex == rhs.text.startIndex && lhs.text.endIndex == rhs.text.endIndex
            && lhs.hiddenAbove == rhs.hiddenAbove && lhs.hiddenBelow == rhs.hiddenBelow
            && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
    }
}

enum TranscriptPiece: Equatable {
    case block(ResponseBlock)
    /// Items of a numbered list, the first one numbered `start`.
    case steps([String], start: Int)
    case code(CodeSlice)
    case table(TableSlice)
    case quote(QuoteSlice)
    /// A mermaid block drawn as its diagram, or shown as this part of its code when it cannot be drawn.
    case diagram(CodeSlice)

    var isText: Bool {
        switch self {
        case let .block(block): block.isText
        case .steps, .code, .table, .quote, .diagram: true
        }
    }
}

/// Part of a table in a row: its header on the first slice only. The slices of one table share its column widths,
/// which come from all of its rows.
struct TableSlice: Equatable {
    let key: String
    /// The whole table, for its column widths.
    let table: TablePayload
    let rows: Range<Int>
    let isFirst: Bool
    let isLast: Bool

    var shownRows: ArraySlice<[String]> { table.rows[rows] }

    /// Rows of the table that are not shown here do not count: they grow in the last slice while an answer streams.
    static func == (lhs: TableSlice, rhs: TableSlice) -> Bool {
        lhs.key == rhs.key && lhs.rows == rhs.rows && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
            && lhs.table.header == rhs.table.header && lhs.shownRows == rhs.shownRows
    }
}

/// Lines of a quote in a row: its bar runs on from the slice above and into the slice below.
struct QuoteSlice: Equatable {
    let text: String
    let isFirst: Bool
    let isLast: Bool
}

struct AssistantPart: Equatable {
    var pieces: [TranscriptPiece]
    /// The work row and the subagents go on the answer's first row, its labels and the streaming block on its last.
    var isFirst: Bool
    var isLast: Bool
}

/// The text a row of a user bubble shows: the preview of a long text, or a slice of it once expanded.
struct UserSlice: Equatable {
    let text: Substring
    /// Characters of the whole text, when the row offers to show all of it.
    let expandableCount: Int?
    let isFirst: Bool
    let isLast: Bool

    static func == (lhs: UserSlice, rhs: UserSlice) -> Bool {
        lhs.text.startIndex == rhs.text.startIndex && lhs.text.endIndex == rhs.text.endIndex
            && lhs.text.base.utf8.count == rhs.text.base.utf8.count
            && lhs.expandableCount == rhs.expandableCount && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
    }
}

enum TranscriptRowContent: Equatable {
    case user(UserSlice)
    case assistant(AssistantPart)
    /// A notice or a chip, laid out as one row.
    case whole
}

struct TranscriptRow: Identifiable, Equatable {
    let messageId: String
    let index: Int
    var joint: TranscriptJoint
    let content: TranscriptRowContent

    var id: String { "\(messageId)#\(index)" }
}

enum TranscriptRows {
    /// Key under which the reader expanded a code block or a pasted text.
    static func codeKey(messageId: String, block: Int) -> String { "\(messageId)#code\(block)" }
    static func textKey(messageId: String) -> String { "\(messageId)#text" }
    /// Key under which the slices of a table share their columns and their sideways scroll.
    static func tableKey(messageId: String, block: Int) -> String { "\(messageId)#table\(block)" }

    /// The rows of one message. `isWhole` lays it out as a single row (a notice, the compacting chip).
    static func rows(
        for message: Message, isLive: Bool, isWhole: Bool, expanded: Set<String>,
        metrics: TranscriptMetrics = TranscriptMetrics(), budget: CGFloat = TranscriptLimits.rowHeight
    ) -> [TranscriptRow] {
        if isWhole { return [TranscriptRow(messageId: message.id, index: 0, joint: .message, content: .whole)] }
        switch message.role {
        case .user:
            return userRows(message, expanded: expanded.contains(textKey(messageId: message.id)), metrics: metrics, budget: budget)
        case .assistant:
            let blocks = ResponseBlockParser.parse(message.text, streaming: isLive)
            return assistantRows(
                messageId: message.id, blocks: blocks, isLive: isLive, header: headerHeight(message, isLive: isLive, metrics: metrics),
                expanded: expanded, metrics: metrics, budget: budget)
        }
    }

    // MARK: User

    private static func userRows(_ message: Message, expanded: Bool, metrics: TranscriptMetrics, budget: CGFloat) -> [TranscriptRow] {
        let attachments = message.attachments ?? []
        let images = attachments.filter { $0.kind != "file" }.count
        let files = attachments.count - images
        let attached = (images == 0 ? 0 : images == 1 ? metrics.image : metrics.image / 2) + CGFloat(files) * metrics.fileChip
        let text = message.text
        func row(_ index: Int, _ slice: UserSlice) -> TranscriptRow {
            TranscriptRow(messageId: message.id, index: index, joint: index == 0 ? .message : .flush, content: .user(slice))
        }
        guard !text.isEmpty else {
            return [row(0, UserSlice(text: text[...], expandableCount: nil, isFirst: true, isLast: true))]
        }
        guard expanded else {
            let preview = TextExcerpt.preview(
                text, maxCharacters: min(TranscriptLimits.pastedPreviewCharacters, metrics.pastedPreviewLines * metrics.bubbleCharactersPerLine),
                maxLines: metrics.pastedPreviewLines)
            return [row(0, UserSlice(text: preview ?? text[...], expandableCount: preview == nil ? nil : text.count, isFirst: true, isLast: true))]
        }
        let room = max(budget - metrics.bubblePadding, metrics.bubbleLine)
        var slices = lineSlices(text, firstRoom: max(room - attached, metrics.bubbleLine), room: room,
                                charactersPerLine: metrics.bubbleCharactersPerLine, line: metrics.bubbleLine)
        if slices.isEmpty { slices = [text[...]] }
        return slices.enumerated().map { index, slice in
            row(index, UserSlice(text: slice, expandableCount: nil, isFirst: index == 0, isLast: index == slices.count - 1))
        }
    }

    // MARK: Assistant

    private static func headerHeight(_ message: Message, isLive: Bool, metrics: TranscriptMetrics) -> CGFloat {
        let work = isLive || !(message.steps ?? []).isEmpty || message.thoughts?.isEmpty == false
        let subagents = !(message.subagents ?? []).isEmpty
        return (work ? metrics.workRow + metrics.blockGap : 0) + (subagents ? metrics.workRow + metrics.blockGap : 0)
    }

    /// What a block is cut into: a line of prose, a list item, a line of code, a table row, or the whole block.
    private enum AtomKind {
        case whole(ResponseBlock)
        case line(String, quote: Bool, first: Bool, last: Bool)
        case item(String)
        case step(String, number: Int)
        case code(CodeAtom)
        case tableRow(Int, of: TablePayload, key: String)
    }

    private struct CodeAtom {
        enum Shown {
            /// The first lines of a finished block.
            case collapsed
            /// The last lines of the block that streams.
            case streaming
            /// One line of a block the reader expanded.
            case line(Int)
        }

        let key: String
        let language: String?
        let code: String
        let shown: Shown
        let lineCount: Int
        var diagram = false
        /// Lines of the excerpt, for a block collapsed or streaming.
        var excerptLines = 0
    }

    private struct Atom {
        let block: Int
        let kind: AtomKind
        let height: CGFloat
        /// Gap above this atom when it carries on its block at the top of a row.
        let joint: TranscriptJoint
    }

    static func assistantRows(
        messageId: String, blocks: [ResponseBlock], isLive: Bool, header: CGFloat, expanded: Set<String>,
        metrics: TranscriptMetrics = TranscriptMetrics(), budget: CGFloat = TranscriptLimits.rowHeight
    ) -> [TranscriptRow] {
        var atoms: [Atom] = []
        for (index, block) in blocks.enumerated() {
            let streaming = isLive && index == blocks.count - 1
            atoms += self.atoms(of: block, index: index, messageId: messageId, streaming: streaming, expanded: expanded,
                                metrics: metrics, budget: budget)
        }
        var rows: [[Atom]] = [[]]
        var height = header
        for atom in atoms {
            let previous = rows[rows.count - 1].last
            let gap = previous == nil ? 0 : previous?.block == atom.block ? 0 : metrics.blockGap
            if previous != nil, height + gap + atom.height > budget {
                rows.append([])
                height = atom.height
            } else {
                height += gap + atom.height
            }
            rows[rows.count - 1].append(atom)
        }
        var result: [TranscriptRow] = []
        var lastBlock: Int?
        for (index, atomsOfRow) in rows.enumerated() {
            let joint: TranscriptJoint
            if index == 0 {
                joint = .message
            } else if let first = atomsOfRow.first, first.block == lastBlock {
                joint = first.joint
            } else {
                joint = .block
            }
            let part = AssistantPart(pieces: pieces(atomsOfRow), isFirst: index == 0, isLast: index == rows.count - 1)
            result.append(TranscriptRow(messageId: messageId, index: index, joint: joint, content: .assistant(part)))
            lastBlock = atomsOfRow.last?.block
        }
        return result
    }

    private static func atoms(
        of block: ResponseBlock, index: Int, messageId: String, streaming: Bool, expanded: Set<String>,
        metrics: TranscriptMetrics, budget: CGFloat
    ) -> [Atom] {
        func whole(_ height: CGFloat) -> [Atom] { [Atom(block: index, kind: .whole(block), height: height, joint: .block)] }
        let lineRoom = max(1, Int(budget / metrics.proseLine) - 1) * metrics.proseCharactersPerLine
        switch block {
        case let .paragraph(text), let .quote(text):
            let quote = if case .quote = block { true } else { false }
            let lines = proseLines(text, maxCharacters: lineRoom)
            return lines.enumerated().map { number, line in
                // A quote keeps the gap between its lines inside its slices, so that its bar runs on unbroken.
                Atom(block: index, kind: .line(line, quote: quote, first: number == 0, last: number == lines.count - 1),
                     height: proseHeight(line, metrics), joint: quote ? .flush : .line)
            }
        case let .heading(_, text):
            return whole(metrics.heading * CGFloat(visualLines(text, metrics.proseCharactersPerLine)))
        case .divider:
            return whole(metrics.divider)
        case let .bulletList(items) where !items.isEmpty:
            return items.map { item in
                Atom(block: index, kind: .item(item), height: proseHeight(item, metrics) + 6, joint: .listItem)
            }
        case let .numberedSteps(items) where !items.isEmpty:
            return items.enumerated().map { number, item in
                Atom(block: index, kind: .step(item, number: number + 1), height: proseHeight(item, metrics) + 6, joint: .listItem)
            }
        case let .table(payload) where !payload.rows.isEmpty:
            let key = tableKey(messageId: messageId, block: index)
            return payload.rows.indices.map { number in
                Atom(block: index, kind: .tableRow(number, of: payload, key: key),
                     height: metrics.tableRow + (number == 0 ? metrics.tableHeader : 0), joint: .flush)
            }
        case let .code(language, body):
            let key = codeKey(messageId: messageId, block: index)
            let count = TextExcerpt.lineCount(body)
            let diagram = language?.lowercased() == "mermaid"
            // A diagram's card is as tall as its drawing, or as its code when it cannot be drawn.
            func height(_ code: CGFloat) -> CGFloat {
                diagram ? max(code + metrics.diagramNote, metrics.codeChrome + TranscriptLimits.diagramHeight) : code
            }
            if streaming {
                let limit = metrics.codeStreamingLines
                let shown = min(count, limit)
                let atom = CodeAtom(key: key, language: language, code: body, shown: .streaming, lineCount: count, diagram: diagram, excerptLines: limit)
                let label = count > shown ? metrics.codeLine : 0
                return [Atom(block: index, kind: .code(atom), height: height(metrics.codeChrome + label + CGFloat(shown) * metrics.codeLine), joint: .flush)]
            }
            let limit = metrics.codeCollapsedLines
            guard expanded.contains(key), count > limit else {
                let shown = min(count, limit)
                let atom = CodeAtom(key: key, language: language, code: body, shown: .collapsed, lineCount: count, diagram: diagram, excerptLines: limit)
                let footer = count > shown ? metrics.codeFooter : 0
                return [Atom(block: index, kind: .code(atom), height: height(metrics.codeChrome + footer + CGFloat(shown) * metrics.codeLine), joint: .flush)]
            }
            return (0..<count).map { line in
                let atom = CodeAtom(key: key, language: language, code: body, shown: .line(line), lineCount: count)
                let chrome = line == 0 ? metrics.codeChrome : 0
                return Atom(block: index, kind: .code(atom), height: chrome + metrics.codeLine, joint: .flush)
            }
        case .bulletList, .numberedSteps, .table:
            return whole(metrics.tableHeader)
        default:
            return whole(metrics.card)
        }
    }

    /// Consecutive atoms of one block in a row become one piece again.
    private static func pieces(_ atoms: [Atom]) -> [TranscriptPiece] {
        var result: [TranscriptPiece] = []
        var index = 0
        while index < atoms.count {
            var end = index + 1
            while end < atoms.count, atoms[end].block == atoms[index].block { end += 1 }
            result += piece(atoms[index..<end])
            index = end
        }
        return result
    }

    private static func piece(_ run: ArraySlice<Atom>) -> [TranscriptPiece] {
        guard let first = run.first else { return [] }
        switch first.kind {
        case let .whole(block):
            return [.block(block)]
        case let .line(_, quote, first, _):
            let text = run.compactMap { if case let .line(line, _, _, _) = $0.kind { line } else { nil } }.joined(separator: "\n")
            guard quote else { return [.block(.paragraph(text))] }
            let last = if case let .line(_, _, _, last)? = run.last?.kind { last } else { true }
            return [first && last ? .block(.quote(text)) : .quote(QuoteSlice(text: text, isFirst: first, isLast: last))]
        case .item:
            return [.block(.bulletList(run.compactMap { if case let .item(item) = $0.kind { item } else { nil } }))]
        case let .step(_, number):
            return [.steps(run.compactMap { if case let .step(item, _) = $0.kind { item } else { nil } }, start: number)]
        case let .tableRow(start, table, key):
            let end = if case let .tableRow(last, _, _)? = run.last?.kind { last + 1 } else { start + 1 }
            guard start > 0 || end < table.rows.count else { return [.block(.table(table))] }
            return [.table(TableSlice(key: key, table: table, rows: start..<end, isFirst: start == 0, isLast: end == table.rows.count))]
        case let .code(atom):
            let slice = codeSlice(run, first: atom)
            return [atom.diagram ? .diagram(slice) : .code(slice)]
        }
    }

    private static func codeSlice(_ run: ArraySlice<Atom>, first atom: CodeAtom) -> CodeSlice {
        func slice(_ text: Substring, above: Int = 0, below: Int = 0, first: Bool = true, last: Bool = true) -> CodeSlice {
            CodeSlice(key: atom.key, language: atom.language, code: atom.code, text: text, hiddenAbove: above, hiddenBelow: below,
                      isFirst: first, isLast: last)
        }
        switch atom.shown {
        case .collapsed:
            let excerpt = TextExcerpt.firstLines(atom.code, atom.excerptLines)
            return slice(excerpt.text, below: excerpt.hidden)
        case .streaming:
            let excerpt = TextExcerpt.lastLines(atom.code, atom.excerptLines)
            return slice(excerpt.text, above: excerpt.hidden)
        case let .line(start):
            var end = start + 1
            if case let .code(last) = run.last?.kind, case let .line(line) = last.shown { end = line + 1 }
            return slice(lineRange(atom.code, start..<end), first: start == 0, last: end == atom.lineCount)
        }
    }

    // MARK: Text

    /// Lines a text takes once wrapped, each line of the source taking at least one.
    static func visualLines<S: StringProtocol>(_ text: S, _ charactersPerLine: Int) -> Int {
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (line.count + charactersPerLine - 1) / charactersPerLine)
        }
        return lines
    }

    private static func proseHeight<S: StringProtocol>(_ text: S, _ metrics: TranscriptMetrics) -> CGFloat {
        CGFloat(visualLines(text, metrics.proseCharactersPerLine)) * metrics.proseLine
    }

    /// The lines of a paragraph; a line too long for a row is cut after a sentence or a word.
    private static func proseLines(_ text: String, maxCharacters: Int) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line -> [String] in
            guard line.count > maxCharacters else { return [String(line)] }
            return wordCuts(line, maxCharacters: maxCharacters).map(String.init)
        }
    }

    /// Cuts a line at the last sentence end, or else the last space, before `maxCharacters`.
    static func wordCuts(_ line: Substring, maxCharacters: Int) -> [Substring] {
        var result: [Substring] = []
        var rest = line
        while rest.count > maxCharacters {
            let limit = rest.index(rest.startIndex, offsetBy: maxCharacters)
            let window = rest[..<limit]
            let cut: String.Index
            if let sentence = window.range(of: ". ", options: .backwards), window.distance(from: window.startIndex, to: sentence.lowerBound) > maxCharacters / 2 {
                cut = sentence.upperBound
            } else if let space = window.lastIndex(of: " "), window.distance(from: window.startIndex, to: space) > maxCharacters / 2 {
                cut = rest.index(after: space)
            } else {
                cut = limit
            }
            result.append(rest[..<cut].trimmingSuffix())
            rest = rest[cut...]
        }
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// The text in slices that each fit `room` (the first one `firstRoom`), cut at line ends, or inside a line too tall
    /// for a slice of its own.
    static func lineSlices(_ text: String, firstRoom: CGFloat, room: CGFloat, charactersPerLine: Int, line: CGFloat) -> [Substring] {
        func height(_ characters: Int) -> CGFloat { CGFloat(max(1, (characters + charactersPerLine - 1) / charactersPerLine)) * line }
        var result: [Substring] = []
        var start = text.startIndex
        var filled: CGFloat = 0
        var limit = firstRoom
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            var segment = cursor
            while true {
                let needed = height(text.distance(from: segment, to: lineEnd))
                if filled > 0, filled + needed > limit {
                    let end = segment > start && text[text.index(before: segment)] == "\n" ? text.index(before: segment) : segment
                    result.append(text[start..<end])
                    start = segment
                    filled = 0
                    limit = room
                }
                guard needed > limit else {
                    filled += needed
                    break
                }
                let next = text.index(segment, offsetBy: max(1, Int(limit / line)) * charactersPerLine)
                result.append(text[start..<next])
                start = next
                segment = next
                limit = room
            }
            cursor = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    private static func lineRange(_ text: String, _ lines: Range<Int>) -> Substring {
        var index = text.startIndex
        var line = 0
        var start = text.startIndex
        while line < lines.lowerBound, let newline = text[index...].firstIndex(of: "\n") {
            index = text.index(after: newline)
            line += 1
        }
        start = index
        while line < lines.upperBound - 1, let newline = text[index...].firstIndex(of: "\n") {
            index = text.index(after: newline)
            line += 1
        }
        let end = text[index...].firstIndex(of: "\n") ?? text.endIndex
        return text[start..<end]
    }
}

private extension Substring {
    func trimmingSuffix() -> Substring {
        var end = endIndex
        while end > startIndex, self[index(before: end)] == " " { end = index(before: end) }
        return self[startIndex..<end]
    }
}

struct TranscriptItem: Identifiable {
    let message: Message
    let row: TranscriptRow

    var id: String { row.id }
}

/// The rows of a conversation, laid out again only for a message that changed: the transcript is rebuilt on every delta
/// of an answer, and only that answer grows.
final class TranscriptRowCache {
    private struct Entry {
        let text: String
        let isLive: Bool
        let isWhole: Bool
        let hasHeader: Bool
        let expanded: Set<String>
        let rows: [TranscriptRow]
    }

    private var entries: [String: Entry] = [:]
    private var metrics = TranscriptMetrics()

    func items(
        for messages: [Message], liveMessageId: String?, expanded: Set<String>, metrics: TranscriptMetrics = TranscriptMetrics(),
        isWhole: (Message) -> Bool = { _ in false }
    ) -> [TranscriptItem] {
        if metrics != self.metrics {
            entries.removeAll()
            self.metrics = metrics
        }
        var items: [TranscriptItem] = []
        var kept: [String: Entry] = [:]
        for message in messages {
            let isLive = message.id == liveMessageId
            let whole = isWhole(message)
            let hasHeader = !(message.steps ?? []).isEmpty || message.thoughts?.isEmpty == false || !(message.subagents ?? []).isEmpty
            let prefix = message.id + "#"
            let mine: Set<String> = expanded.isEmpty ? [] : expanded.filter { $0.hasPrefix(prefix) }
            let rows: [TranscriptRow]
            if let entry = entries[message.id], entry.isLive == isLive, entry.isWhole == whole, entry.hasHeader == hasHeader,
               entry.expanded == mine, entry.text == message.text {
                rows = entry.rows
            } else {
                rows = TranscriptRows.rows(for: message, isLive: isLive, isWhole: whole, expanded: mine, metrics: metrics)
            }
            kept[message.id] = Entry(text: message.text, isLive: isLive, isWhole: whole, hasHeader: hasHeader, expanded: mine, rows: rows)
            for row in rows {
                var row = row
                if items.isEmpty { row.joint = .start }
                items.append(TranscriptItem(message: message, row: row))
            }
        }
        entries = kept
        return items
    }
}
