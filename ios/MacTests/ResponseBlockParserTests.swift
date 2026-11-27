import Testing

struct ResponseBlockParserTests {
    private let delayed = CalloutPayload(style: .info, title: nil, text: "Le colis arrive demain avant 13 h.")

    @Test func anUnbalancedShorthandKeepsTheRestOfTheAnswer() {
        let text = """
        ::warning: la liste [en cours
        Le train de 18 h 04 est supprimé.
        Prends le car de remplacement devant la gare.
        """
        #expect(ResponseBlockParser.parse(text) == [
            .callout(CalloutPayload(style: .warning, title: nil, text: "la liste [en cours")),
            .paragraph("Le train de 18 h 04 est supprimé.\nPrends le car de remplacement devant la gare."),
        ])
    }

    @Test func aMarkerThatNeverClosesShowsAsTextOnceTheAnswerIsDone() {
        let text = """
        ::chart {"title":"Ventes de septembre","series":[
        Le chiffre d'affaires a progressé de 12 %.
        """
        #expect(ResponseBlockParser.parse(text) == [
            .paragraph(#"::chart {"title":"Ventes de septembre","series":["# + "\nLe chiffre d'affaires a progressé de 12 %."),
        ])
        #expect(ResponseBlockParser.plainText(text) == "Le chiffre d'affaires a progressé de 12 %.")
    }

    @Test func aMarkerStillArrivingIsHiddenWhileStreaming() {
        let text = """
        Voici l'évolution du mois :
        ::chart {"title":"Ventes de septembre",
        "series":[
        """
        #expect(ResponseBlockParser.parse(text, streaming: true) == [.paragraph("Voici l'évolution du mois :")])

        let shorthand = "Voici le programme :\n::après-midi"
        #expect(ResponseBlockParser.parse(shorthand, streaming: true) == [.paragraph("Voici le programme :")])
        #expect(ResponseBlockParser.parse(shorthand) == [.paragraph("Voici le programme :"), .paragraph("::après-midi")])
    }

    @Test func anOpenMarkerGivesUpPastTheLineLimit() {
        let marker = #"::chart {"title":"Ventes de septembre","series":["#
        let steps = (1...CardMarkup.maxMarkerLines + 20).map { "Étape \($0) du déploiement terminée" }
        let segments = CardMarkup.segments(in: ([marker] + steps).joined(separator: "\n"), streaming: true)
        #expect(segments.first?.text == marker)
        #expect(segments.count == steps.count + 1)
    }

    @Test func aMarkerSpreadOverLinesStillCloses() {
        let text = """
        ::callout {"style":"info",
          "text":"Le colis arrive demain avant 13 h."}
        Pense à laisser le portail ouvert.
        """
        #expect(ResponseBlockParser.parse(text) == [.callout(delayed), .paragraph("Pense à laisser le portail ouvert.")])
    }

    @Test func aFenceOfCardsIsUnwrappedOnlyOnceClosed() {
        let card = #"::callout {"style":"info","text":"Le colis arrive demain avant 13 h."}"#
        #expect(ResponseBlockParser.parse("```\n\(card)\n```") == [.callout(delayed)])
        #expect(ResponseBlockParser.parse("```\n\(card)", streaming: true) == [.code(language: nil, body: card)])
    }

    @Test func codeWithDoubleColonsStaysCode() {
        let code = "std::vector<int> stops = line.stops();\nstd::sort(stops.begin(), stops.end());"
        #expect(ResponseBlockParser.parse("```cpp\n\(code)\n```") == [.code(language: "cpp", body: code)])
    }
}
