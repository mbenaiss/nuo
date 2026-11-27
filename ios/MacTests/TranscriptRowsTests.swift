import CoreGraphics
import Foundation
import Testing

struct TranscriptRowsTests {
    private let metrics = TranscriptMetrics()
    private let budget = TranscriptLimits.rowHeight

    /// A pasted itinerary as a person sends it to the travel bot: 469 long lines.
    private let itinerary = (1...469).map {
        "Jour \($0) : départ de Rome à 14:40, arrivée à Paris Orly à 17:05, porte F32, sièges 6D 6E 6F, bagage en soute de 23 kg."
    }

    private let swiftLines = (1...180).map { "    let leg\($0) = FlightLeg(number: \"TO\(8200 + $0)\", from: \"TUN\", to: \"ORY\", gate: \"F32\")" }

    private func answer(_ text: String, id: String = "a-lisbonne", steps: Bool = true) -> Message {
        Message(
            id: id, conversationId: "c-voyages-1", role: .assistant, text: text,
            steps: steps ? [ToolStep(toolCallId: "t1", title: "booking_lookup", kind: "fetch", status: .completed, durationMs: 900)] : nil,
            durationMs: 4_000, stopReason: .endTurn, createdAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    private func pasted(_ text: String) -> Message {
        Message(id: "u-colle", conversationId: "c-voyages-1", role: .user, text: text, createdAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    private func parts(_ rows: [TranscriptRow]) -> [AssistantPart] {
        rows.compactMap { if case let .assistant(part) = $0.content { part } else { nil } }
    }

    private func codeSlices(_ rows: [TranscriptRow]) -> [CodeSlice] {
        parts(rows).flatMap(\.pieces).compactMap { if case let .code(slice) = $0 { slice } else { nil } }
    }

    @Test func aShortAnswerIsOneRowWithItsHeaderAndFooter() {
        let rows = TranscriptRows.rows(
            for: answer("Oui, **TO8285 Rome → Paris** est annoncé à l'heure. L'embarquement ouvre à 13:55."),
            isLive: false, isWhole: false, expanded: [])
        #expect(rows.map(\.id) == ["a-lisbonne#0"])
        #expect(rows[0].joint == .message)
        #expect(parts(rows).first.map { $0.isFirst && $0.isLast } == true)
    }

    @Test func aLongAnswerIsCutBetweenItsParagraphs() {
        let text = "Voici ton programme :\n\n" + itinerary.joined(separator: "\n\n")
        let rows = TranscriptRows.rows(for: answer(text), isLive: false, isWhole: false, expanded: [])
        #expect(rows.count > 20)
        #expect(rows.map(\.id) == rows.indices.map { "a-lisbonne#\($0)" })
        #expect(parts(rows).first?.isFirst == true && parts(rows).last?.isLast == true)
        #expect(parts(rows).dropFirst().allSatisfy { !$0.isFirst })
        #expect(rows.dropFirst().allSatisfy { $0.joint == .block })
        let paragraphs = parts(rows).flatMap(\.pieces).compactMap { if case let .block(.paragraph(text)) = $0 { text } else { nil } }
        #expect(paragraphs == ["Voici ton programme :"] + itinerary)
        for part in parts(rows) {
            let lines = part.pieces.reduce(0) { lines, piece in
                guard case let .block(.paragraph(text)) = piece else { return lines }
                return lines + TranscriptRows.visualLines(text, metrics.proseCharactersPerLine)
            }
            #expect(CGFloat(lines) * metrics.proseLine <= budget)
        }
    }

    @Test func aParagraphTallerThanARowCarriesOnLineByLine() {
        let rows = TranscriptRows.rows(for: answer(itinerary.joined(separator: "\n"), steps: false), isLive: false, isWhole: false, expanded: [])
        #expect(rows.count > 1)
        #expect(rows.dropFirst().allSatisfy { $0.joint == .line })
        let pieces = parts(rows).flatMap(\.pieces).compactMap { if case let .block(.paragraph(text)) = $0 { text } else { nil } }
        #expect(pieces.joined(separator: "\n") == itinerary.joined(separator: "\n"))
    }

    @Test func aLineLongerThanARowIsCutAfterASentence() {
        let sentence = "Le vol TO8285 part de Rome à 14:40 et arrive à Orly à 17:05. "
        let line = String(repeating: sentence, count: 120)
        let cuts = TranscriptRows.wordCuts(line[...], maxCharacters: 600)
        #expect(cuts.count > 1)
        #expect(cuts.dropLast().allSatisfy { $0.count <= 600 && $0.hasSuffix("17:05.") })
        #expect(cuts.joined(separator: " ").trimmingCharacters(in: .whitespaces) == line.trimmingCharacters(in: .whitespaces))
    }

    @Test func aFinishedCodeBlockShowsItsFirstLines() {
        let code = swiftLines.joined(separator: "\n")
        let rows = TranscriptRows.rows(for: answer("Le modèle :\n\n```swift\n\(code)\n```"), isLive: false, isWhole: false, expanded: [])
        let slices = codeSlices(rows)
        #expect(slices.count == 1)
        #expect(slices[0].text == swiftLines.prefix(TranscriptLimits.codeCollapsedLines).joined(separator: "\n"))
        #expect(slices[0].hiddenBelow == swiftLines.count - TranscriptLimits.codeCollapsedLines)
        #expect(slices[0].code == code)
        #expect(slices[0].key == TranscriptRows.codeKey(messageId: "a-lisbonne", block: 1))
    }

    @Test func anExpandedCodeBlockIsCutIntoSlicesOfOneSurface() {
        let code = swiftLines.joined(separator: "\n")
        let message = answer("Le modèle :\n\n```swift\n\(code)\n```\n\nIl couvre les 180 vols de la saison.")
        let rows = TranscriptRows.rows(
            for: message, isLive: false, isWhole: false, expanded: [TranscriptRows.codeKey(messageId: message.id, block: 1)])
        let slices = codeSlices(rows)
        #expect(slices.count > 3)
        #expect(slices.map(\.text).joined(separator: "\n") == code)
        #expect(slices.first?.isFirst == true && slices.last?.isLast == true)
        #expect(slices.dropFirst().allSatisfy { !$0.isFirst } && slices.dropLast().allSatisfy { !$0.isLast })
        #expect(slices.allSatisfy { $0.hiddenBelow == 0 && $0.code == code })
        #expect(slices.allSatisfy { CGFloat(TextExcerpt.lineCount($0.text)) * metrics.codeLine <= budget })
        // Rows that carry on the card sit flush under the row above.
        let carrying = rows.filter { row in
            guard case let .assistant(part) = row.content, case let .code(slice)? = part.pieces.first else { return false }
            return !slice.isFirst
        }
        #expect(!carrying.isEmpty && carrying.allSatisfy { $0.joint == .flush })
    }

    @Test func aStreamingCodeBlockShowsItsLastLines() {
        let code = swiftLines.joined(separator: "\n")
        let rows = TranscriptRows.rows(for: answer("```swift\n\(code)"), isLive: true, isWhole: false, expanded: [])
        let slices = codeSlices(rows)
        #expect(slices.count == 1)
        #expect(slices[0].text == swiftLines.suffix(TranscriptLimits.codeStreamingLines).joined(separator: "\n"))
        #expect(slices[0].hiddenAbove == swiftLines.count - TranscriptLimits.codeStreamingLines)
    }

    @Test(arguments: [false, true])
    func rowsAlreadyShownKeepTheirIdAndContentWhileTheAnswerGrows(table: Bool) {
        let full = table
            ? "Voici les vols de la saison :\n\n" + flightTable(flightRows + flightRows.map { $0.replacingOccurrences(of: "| TO8", with: "| TO9") })
            : "Voici ton programme :\n\n" + itinerary.joined(separator: "\n\n")
        var previous: [TranscriptRow] = []
        for length in stride(from: 2_000, through: full.count, by: table ? 230 : 1_700) {
            let text = String(full.prefix(length))
            let rows = TranscriptRows.rows(for: answer(text), isLive: true, isWhole: false, expanded: [])
            if previous.count > 2 {
                // Only the last row grows, or moves its last lines to a new row.
                #expect(Array(rows.prefix(previous.count - 2)) == Array(previous.prefix(previous.count - 2)))
            }
            #expect(rows.count >= previous.count - 1)
            previous = rows
        }
        if table { #expect(tableSlices(previous).count > 2) }
    }

    @Test func aNumberedListCarriesOnItsNumbering() {
        let steps = (1...60).map { "Présenter le passeport et la carte d'embarquement au contrôle \($0), puis rejoindre la porte F32 avant 13:55." }
        let text = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let rows = TranscriptRows.rows(for: answer(text, steps: false), isLive: false, isWhole: false, expanded: [])
        let lists = parts(rows).flatMap(\.pieces).compactMap { piece -> (items: [String], start: Int)? in
            if case let .steps(items, start) = piece { (items, start) } else { nil }
        }
        #expect(lists.count > 1)
        #expect(lists.flatMap(\.items) == steps)
        var next = 1
        for list in lists {
            #expect(list.start == next)
            next += list.items.count
        }
        #expect(rows.dropFirst().allSatisfy { $0.joint == .listItem })
    }

    private let flightRows = (1...80).map { number in
        "| TO\(8200 + number) | Rome Fiumicino | \(number < 60 ? "Paris Orly" : "Paris Charles-de-Gaulle Terminal 2E") | F\(number % 40) |"
    }

    private func flightTable(_ rows: [String]) -> String {
        (["| Vol | Départ | Arrivée | Porte |", "|---|---|---|---|"] + rows).joined(separator: "\n")
    }

    private func tableSlices(_ rows: [TranscriptRow]) -> [TableSlice] {
        parts(rows).flatMap(\.pieces).compactMap { if case let .table(slice) = $0 { slice } else { nil } }
    }

    @Test func aLongTableIsOneTableAcrossRows() {
        let rows = TranscriptRows.rows(for: answer(flightTable(flightRows), steps: false), isLive: false, isWhole: false, expanded: [])
        let slices = tableSlices(rows)
        #expect(slices.count > 1)
        // The header only on the first slice, and the slices follow each other row after row.
        #expect(slices.map(\.isFirst) == [true] + Array(repeating: false, count: slices.count - 1))
        #expect(slices.map(\.isLast) == Array(repeating: false, count: slices.count - 1) + [true])
        #expect(slices.first?.rows.lowerBound == 0 && slices.last?.rows.upperBound == 80)
        #expect(zip(slices, slices.dropFirst()).allSatisfy { $0.rows.upperBound == $1.rows.lowerBound })
        #expect(slices.flatMap(\.shownRows).map { $0[0] } == (1...80).map { "TO\(8200 + $0)" })
        // Every slice sizes its columns from the whole table, under one key.
        #expect(slices.allSatisfy { $0.table.rows.count == 80 && $0.table.header == ["Vol", "Départ", "Arrivée", "Porte"] })
        #expect(Set(slices.map(\.key)) == [TranscriptRows.tableKey(messageId: "a-lisbonne", block: 0)])
        #expect(rows.dropFirst().allSatisfy { $0.joint == .flush })
        #expect(slices.allSatisfy { CGFloat($0.rows.count) * metrics.tableRow <= budget })
    }

    @Test func aShortTableStaysOneWholeTable() {
        let text = "Tes vols :\n\n" + flightTable(Array(flightRows.prefix(4)))
        let rows = TranscriptRows.rows(for: answer(text, steps: false), isLive: false, isWhole: false, expanded: [])
        #expect(rows.count == 1)
        #expect(tableSlices(rows).isEmpty)
        let tables = parts(rows).flatMap(\.pieces).compactMap { if case let .block(.table(table)) = $0 { table } else { nil } }
        #expect(tables.map(\.rows.count) == [4])
    }

    @Test func columnWidthsComeFromTheWholeTableAndAreMeasuredOnce() {
        let header = ["Vol", "Arrivée", "Porte"]
        let rows = (1...80).map { ["TO\(8200 + $0)", $0 == 61 ? "Paris Charles-de-Gaulle Terminal 2E" : "Lyon", "F\($0 % 40)"] }
        var measured = 0
        let measure: (String, Bool) -> CGFloat = { text, isHeader in
            measured += 1
            return CGFloat(text.count) * (isHeader ? 7 : 8)
        }
        var columns = TableColumns(header: header, measure: measure)
        // Streamed row by row, the widths end as those of the whole table measured at once.
        for count in 1...rows.count { _ = columns.widths(rows: Array(rows.prefix(count)), measure: measure) }
        let streamed = columns.widths(rows: rows, measure: measure)
        var whole = TableColumns(header: header, measure: measure)
        #expect(streamed == whole.widths(rows: rows, measure: measure))
        let expected: [CGFloat] = [48, 280, 35]
        #expect(streamed == expected)
        measured = 0
        _ = columns.widths(rows: rows, measure: measure)
        #expect(measured == header.count)
    }

    @Test func aLongQuoteKeepsOneBarAcrossRows() {
        let text = itinerary.prefix(120).map { "> " + $0 }.joined(separator: "\n")
        let rows = TranscriptRows.rows(for: answer(text, steps: false), isLive: false, isWhole: false, expanded: [])
        let slices = parts(rows).flatMap(\.pieces).compactMap { if case let .quote(slice) = $0 { slice } else { nil } }
        #expect(slices.count == rows.count && slices.count > 1)
        #expect(slices.map(\.text).joined(separator: "\n") == itinerary.prefix(120).joined(separator: "\n"))
        #expect(slices.map(\.isFirst) == [true] + Array(repeating: false, count: slices.count - 1))
        #expect(slices.map(\.isLast) == Array(repeating: false, count: slices.count - 1) + [true])
        #expect(rows.dropFirst().allSatisfy { $0.joint == .flush })
    }

    @Test func aShortQuoteStaysOneBlock() {
        let rows = TranscriptRows.rows(
            for: answer("> Embarquement porte F32 à 13:55.", steps: false), isLive: false, isWhole: false, expanded: [])
        #expect(parts(rows).flatMap(\.pieces) == [.block(.quote("Embarquement porte F32 à 13:55."))])
    }

    @Test func aDiagramShowsAtMostACollapsedCodeInOneRow() {
        let lines = (1...400).map { "étape \($0) --> vol TO\(8200 + $0) ((Rome))) départ 14:40" }
        let message = answer("Le parcours :\n\n```mermaid\n\(lines.joined(separator: "\n"))\n```\n\nIl couvre 400 étapes.", steps: false)
        let rows = TranscriptRows.rows(for: message, isLive: false, isWhole: false, expanded: [])
        let diagrams = parts(rows).flatMap(\.pieces).compactMap { if case let .diagram(slice) = $0 { slice } else { nil } }
        #expect(diagrams.count == 1)
        #expect(diagrams.first.map { String($0.text) } == lines.prefix(TranscriptLimits.codeCollapsedLines).joined(separator: "\n"))
        #expect(diagrams.first?.hiddenBelow == 400 - TranscriptLimits.codeCollapsedLines)
        #expect(diagrams.first?.code == lines.joined(separator: "\n"))
        // The drawing, its code collapsed and the note under it each fit in a row.
        let collapsed = metrics.codeChrome + metrics.codeFooter + CGFloat(TranscriptLimits.codeCollapsedLines) * metrics.codeLine
        #expect(collapsed + metrics.diagramNote <= budget)
        #expect(metrics.codeChrome + TranscriptLimits.diagramHeight <= budget)

        let expanded = TranscriptRows.rows(
            for: message, isLive: false, isWhole: false, expanded: [TranscriptRows.codeKey(messageId: message.id, block: 1)])
        let slices = codeSlices(expanded)
        #expect(slices.count > 3)
        #expect(slices.map(\.text).joined(separator: "\n") == lines.joined(separator: "\n"))
        #expect(slices.allSatisfy { CGFloat(TextExcerpt.lineCount($0.text)) * metrics.codeLine <= budget })
    }

    @Test func aStreamingDiagramShowsTheLastLinesOfItsCode() {
        let lines = (1...200).map { "    S\($0)[Contrôle \($0)] --> S\($0 + 1)[Contrôle \($0 + 1)]" }
        let rows = TranscriptRows.rows(
            for: answer("```mermaid\nflowchart TD\n\(lines.joined(separator: "\n"))"), isLive: true, isWhole: false, expanded: [])
        let diagrams = parts(rows).flatMap(\.pieces).compactMap { if case let .diagram(slice) = $0 { slice } else { nil } }
        #expect(diagrams.first.map { String($0.text) } == lines.suffix(TranscriptLimits.codeStreamingLines).joined(separator: "\n"))
    }

    @Test func aPastedTextShowsItsStartUntilExpanded() {
        let text = itinerary.joined(separator: "\n")
        let rows = TranscriptRows.rows(for: pasted(text), isLive: false, isWhole: false, expanded: [])
        guard rows.count == 1, case let .user(slice) = rows[0].content else {
            Issue.record("one row expected, got \(rows.count)")
            return
        }
        #expect(slice.text.count <= TranscriptLimits.pastedPreviewCharacters)
        #expect(slice.expandableCount == text.count)
        #expect(slice.isFirst && slice.isLast)
    }

    @Test func anExpandedPastedTextIsCutAtLineEnds() {
        let text = itinerary.joined(separator: "\n")
        let rows = TranscriptRows.rows(for: pasted(text), isLive: false, isWhole: false, expanded: [TranscriptRows.textKey(messageId: "u-colle")])
        let slices = rows.compactMap { if case let .user(slice) = $0.content { slice } else { nil } }
        #expect(slices.count > 10)
        #expect(slices.map { String($0.text) }.joined(separator: "\n") == text)
        #expect(slices.allSatisfy { $0.expandableCount == nil })
        #expect(rows.dropFirst().allSatisfy { $0.joint == .flush })
        let room = budget - metrics.bubblePadding
        #expect(slices.allSatisfy { CGFloat(TranscriptRows.visualLines($0.text, metrics.bubbleCharactersPerLine)) * metrics.bubbleLine <= room })
    }

    @Test func aPastedLineWithoutBreaksIsCutWhereASliceIsFull() {
        let text = String(repeating: "Note de frais déplacement Lyon, taxi gare Part-Dieu 32 €. ", count: 400)
        let slices = TranscriptRows.lineSlices(text, firstRoom: 300, room: 300, charactersPerLine: 30, line: 22)
        #expect(slices.count > 1)
        #expect(slices.joined() == text)
        #expect(slices.dropLast().allSatisfy { $0.count == 13 * 30 })
    }

    @Test func aNoticeIsOneWholeRow() {
        let rows = TranscriptRows.rows(for: answer("::notice {\"kind\":\"compacted\"}"), isLive: false, isWhole: true, expanded: [])
        #expect(rows == [TranscriptRow(messageId: "a-lisbonne", index: 0, joint: .message, content: .whole)])
    }

    @Test func theCacheLaysOutAgainOnlyTheMessageThatChanged() {
        let cache = TranscriptRowCache()
        let question = Message(id: "u-1", conversationId: "c-voyages-1", role: .user, text: "Mon vol de lundi est à l'heure ?", createdAt: Date())
        let live = answer("Je regarde le statut du vol TO8285", id: "a-live")
        let first = cache.items(for: [question, live], liveMessageId: "a-live", expanded: [])
        #expect(first.first?.row.joint == .start)
        #expect(first.map(\.id) == ["u-1#0", "a-live#0"])

        var grown = live
        grown.text += " : il est annoncé à l'heure, embarquement à 13:55."
        let second = cache.items(for: [question, grown], liveMessageId: "a-live", expanded: [])
        #expect(second.map(\.id) == ["u-1#0", "a-live#0"])
        #expect(second[1].row != first[1].row)
        #expect(second[0].row == first[0].row)

        let expanded = cache.items(
            for: [question, answer("```swift\n\(swiftLines.joined(separator: "\n"))\n```", id: "a-live")], liveMessageId: nil,
            expanded: [TranscriptRows.codeKey(messageId: "a-live", block: 0), TranscriptRows.codeKey(messageId: "a-autre", block: 0)])
        #expect(expanded.count > 3)
    }

    @Test func atTheLargestTextSizeExcerptsShortenSoThatARowStaysUnderAScreen() {
        let large = TranscriptMetrics().scaled(by: 3.1)
        let code = swiftLines.joined(separator: "\n")
        let finished = TranscriptRows.rows(
            for: answer("Le modèle :\n\n```swift\n\(code)\n```"), isLive: false, isWhole: false, expanded: [], metrics: large)
        let collapsed = codeSlices(finished)
        #expect(collapsed.count == 1)
        #expect(TextExcerpt.lineCount(collapsed[0].text) == large.codeCollapsedLines)
        #expect(collapsed[0].hiddenBelow == swiftLines.count - large.codeCollapsedLines)
        #expect(large.codeChrome + large.codeFooter + CGFloat(large.codeCollapsedLines) * large.codeLine <= budget)

        let streaming = codeSlices(TranscriptRows.rows(for: answer("```swift\n\(code)"), isLive: true, isWhole: false, expanded: [], metrics: large))
        #expect(streaming.first.map { TextExcerpt.lineCount($0.text) } == large.codeStreamingLines)
        #expect(large.codeChrome + large.codeLine + CGFloat(large.codeStreamingLines) * large.codeLine <= 890)

        let rows = TranscriptRows.rows(for: pasted(itinerary.joined(separator: "\n")), isLive: false, isWhole: false, expanded: [], metrics: large)
        guard rows.count == 1, case let .user(slice) = rows[0].content else {
            Issue.record("one row expected, got \(rows.count)")
            return
        }
        #expect(CGFloat(TranscriptRows.visualLines(slice.text, large.bubbleCharactersPerLine)) * large.bubbleLine <= budget)
    }

    @Test func atTheDefaultTextSizeExcerptsKeepTheirLength() {
        #expect(metrics.codeCollapsedLines == TranscriptLimits.codeCollapsedLines)
        #expect(metrics.codeStreamingLines == TranscriptLimits.codeStreamingLines)
        #expect(metrics.pastedPreviewLines == TranscriptLimits.pastedPreviewLines)
    }
}
