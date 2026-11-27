import Testing

struct TextExcerptTests {
    private let log = (1...10).map { "2026-10-31T09:14:0\($0 % 10)Z [runner] étape \($0) du déploiement" }

    @Test func countsLines() {
        #expect(TextExcerpt.lineCount("") == 1)
        #expect(TextExcerpt.lineCount(log.joined(separator: "\n")) == 10)
    }

    @Test func keepsTheLastLinesOfAStreamingBlock() {
        let excerpt = TextExcerpt.lastLines(log.joined(separator: "\n"), 3)
        #expect(excerpt.text == log[7...].joined(separator: "\n"))
        #expect(excerpt.hidden == 7)
        #expect(TextExcerpt.lastLines(log.joined(separator: "\n"), 12).hidden == 0)
    }

    @Test func keepsTheFirstLinesOfAFinishedBlock() {
        let excerpt = TextExcerpt.firstLines(log.joined(separator: "\n"), 3)
        #expect(excerpt.text == log[..<3].joined(separator: "\n"))
        #expect(excerpt.hidden == 7)
        #expect(TextExcerpt.firstLines(log.joined(separator: "\n"), 10).hidden == 0)
    }

    @Test func previewsALongPaste() {
        let short = "Le vol AF1234 Paris-Lisbonne décolle à 07:35 du terminal 2F."
        #expect(TextExcerpt.preview(short, maxCharacters: 3_000, maxLines: 40) == nil)

        let manyLines = (1...60).map { "Ligne \($0) du rapport de livraison" }.joined(separator: "\n")
        let byLines = TextExcerpt.preview(manyLines, maxCharacters: 3_000, maxLines: 40)
        #expect(byLines.map { TextExcerpt.lineCount($0) } == 40)
        #expect(byLines?.hasSuffix("Ligne 40 du rapport de livraison") == true)

        let oneLine = String(repeating: "Résumé de la réunion budget 2027. ", count: 200)
        #expect(TextExcerpt.preview(oneLine, maxCharacters: 3_000, maxLines: 40)?.count == 3_000)
    }

    @Test func aPreviewEndsOnANearbyLineEnd() {
        let paragraph = String(repeating: "a", count: 2_900)
        let text = paragraph + "\n" + String(repeating: "Note de frais déplacement Lyon. ", count: 20)
        #expect(TextExcerpt.preview(text, maxCharacters: 3_000, maxLines: 40) == paragraph[...])
    }

    @Test func splitsAtLineEnds() {
        let text = (1...300).map { "Commande ORD-2026-\(104_000 + $0) livrée à Julie Martin" }.joined(separator: "\n")
        let pieces = TextExcerpt.chunks(text, maxCharacters: 1_000)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 1_000 })
        #expect(pieces.joined(separator: "\n") == text)
    }

    @Test func cutsALineLongerThanAPiece() {
        let minified = String(repeating: #"{"order":"ORD-2026-104857","status":"shipped"},"#, count: 100)
        let text = "Export brut :\n" + minified
        let pieces = TextExcerpt.chunks(text, maxCharacters: 1_000)
        #expect(pieces.first == "Export brut :")
        #expect(pieces.dropFirst().joined() == minified)
        #expect(pieces.allSatisfy { $0.count <= 1_000 })
    }
}
