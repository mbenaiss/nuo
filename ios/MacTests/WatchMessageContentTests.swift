import Testing

struct WatchMessageContentTests {
    static let agenda = """
    Voici ton agenda du jour, lundi 16 novembre :

    | Heure | Rendez-vous | Calendrier |
    |---|---|---|
    | 09:05 – 09:15 | Point avec Julie (*déjà passé*) | Lumen Studio Clients |
    | 14:00 – 15:00 | Revue des retours ORD-2026-104857 | Clients |
    """

    static let mixed = """
    ## Salon de Lyon
    - Envoyer le devis à Julie Martin
    - Réserver le stand B12
    ::event {"title":"Revue devis salon de Lyon","start":"2026-11-19T14:00","end":"2026-11-19T15:00","location":"Visio"}
    | Tâche | Échéance | Responsable |
    |---|---|---|
    | Envoyer le devis | 17/11 | Julie Martin |
    | Réserver le stand | 20/11 | Karim Haddad |
    """

    @Test func anAgendaTableBecomesOneCardPerMeeting() throws {
        let blocks = MessageContent.blocks(Self.agenda)
        #expect(blocks.first == .paragraph("Voici ton agenda du jour, lundi 16 novembre :"))
        guard case let .table(table) = try #require(blocks.last) else { Issue.record("no table"); return }
        #expect(table.hidden == 0)
        #expect(table.rows == [
            WatchTable.Row(time: "09:05 – 09:15", title: "Point avec Julie (*déjà passé*)",
                           lines: [.init(label: "Calendrier", value: "Lumen Studio Clients")]),
            WatchTable.Row(time: "14:00 – 15:00", title: "Revue des retours ORD-2026-104857",
                           lines: [.init(label: "Calendrier", value: "Clients")]),
        ])
    }

    @Test func aLongTableLeavesItsLastRowsToTheIPhone() {
        let rows = (1...9).map { ["\(8 + $0):00", "Rendez-vous client n°\($0)", "Clients"] }
        let table = WatchTable(TablePayload(header: ["Heure", "Rendez-vous", "Calendrier"], rows: rows))
        #expect(table.rows.count == WatchTable.shownRows)
        #expect(table.hidden == 3)
        #expect(table.spokenText.hasSuffix("And 3 more rows on the iPhone."))
    }

    @Test func aTableWithoutATimeUsesItsFirstTextColumnAsTitle() {
        let table = WatchTable(TablePayload(header: ["", "iPhone 17", "Pixel 10"], rows: [["Prix", "969 €", "899 €"], ["Autonomie", "22 h", "24 h"]]))
        #expect(table.rows.first == WatchTable.Row(time: nil, title: "Prix", lines: [
            .init(label: "iPhone 17", value: "969 €"), .init(label: "Pixel 10", value: "899 €"),
        ]))
    }

    @Test func aMixedAnswerKeepsItsHeadingListEventAndTable() throws {
        let blocks = MessageContent.blocks(Self.mixed)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading("Salon de Lyon"))
        #expect(blocks[1] == .bullets(["Envoyer le devis à Julie Martin", "Réserver le stand B12"]))
        guard case let .card(.event(title, when, location)) = blocks[2] else { Issue.record("no event card"); return }
        #expect(title == "Revue devis salon de Lyon")
        #expect(location == "Visio")
        #expect(when?.hasSuffix("14:00–15:00") == true)
        guard case let .table(table) = blocks[3] else { Issue.record("no table"); return }
        #expect(table.rows.map(\.time) == ["17/11", "20/11"])
        #expect(table.rows.map(\.title) == ["Envoyer le devis", "Réserver le stand"])
        #expect(table.rows.first?.lines == [.init(label: "Responsable", value: "Julie Martin")])
    }

    @Test func spokenAnswersHaveNoTableSyntax() {
        let spoken = MessageContent.spokenText(Self.agenda)
        #expect(!spoken.contains("|"))
        #expect(!spoken.contains("---"))
        #expect(!spoken.contains("*"))
        #expect(spoken == """
        Voici ton agenda du jour, lundi 16 novembre :
        09:05 – 09:15, Point avec Julie (déjà passé), Lumen Studio Clients
        14:00 – 15:00, Revue des retours ORD-2026-104857, Clients
        """)
    }

    @Test func spokenAnswersSkipCardJSONAndCode() {
        let answer = """
        Tu as marché **10 400 pas** mardi, plus que lundi.
        ::chart {"title":"Pas par jour","points":[["Lun",8200],["Mar",10400]]}
        ::boarding {"gate":"F32"}
        ```
        steps = [8200, 10400]
        ```
        """
        let spoken = MessageContent.spokenText(answer)
        #expect(spoken == "Tu as marché 10 400 pas mardi, plus que lundi.")
        #expect(MessageContent.blocks(answer).contains(.card(.phoneOnly(kind: "Chart", symbol: "chart.bar.fill", title: "Pas par jour"))))
    }

    @Test func aStreamingAnswerShowsItsRowsButNotAHalfWrittenCard() {
        let partial = Self.agenda + "\n::event {\"title\":\"Revue"
        let blocks = MessageContent.blocks(partial, streaming: true)
        #expect(blocks.count == 2)
        guard case let .table(table) = blocks.last else { Issue.record("no table"); return }
        #expect(table.rows.count == 2)
    }
}
