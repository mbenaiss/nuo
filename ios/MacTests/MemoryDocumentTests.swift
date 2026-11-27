import Foundation
import Testing

struct MemoryDocumentTests {
    private let text = """
    # Julie Martin
    - 2026-10-02 Préfère le train à l'avion pour Lyon
    - 2026-10-09 Allergique aux fruits à coque
    - 2026-10-14 Réunion d'équipe le mardi à 10 h

    """

    @Test func aFactIsFoundAgainAfterAnEarlierLineWasRemoved() throws {
        let shown = MemoryDocument(text)
        let meeting = try #require(shown.facts.last)
        var current = shown
        let removedFirst = current.remove(try #require(shown.facts.first))
        let removedMeeting = current.remove(meeting)
        #expect(removedFirst && removedMeeting)
        #expect(current.facts.map(\.text) == ["Allergique aux fruits à coque"])
    }

    @Test func aFactTheBotAddedMeanwhileSurvivesAnEdit() throws {
        let shown = MemoryDocument(text)
        var current = MemoryDocument(text + "- 2026-10-20 Part à Lisbonne du 2 au 6 novembre\n")
        let updated = current.update(try #require(shown.facts.first), text: "Préfère le train,  même pour Marseille")
        #expect(updated)
        #expect(current.facts.map(\.text) == [
            "Préfère le train, même pour Marseille",
            "Allergique aux fruits à coque",
            "Réunion d'équipe le mardi à 10 h",
            "Part à Lisbonne du 2 au 6 novembre",
        ])
        #expect(current.facts.first?.day == "2026-10-02")
    }

    @Test func aFactAlreadyGoneIsRefused() throws {
        let shown = MemoryDocument(text)
        let allergy = shown.facts[1]
        var current = shown
        let removed = current.remove(allergy)
        let before = current.content
        let removedAgain = current.remove(allergy)
        let updated = current.update(allergy, text: "Allergique aux arachides")
        #expect(removed && !removedAgain && !updated)
        #expect(current.content == before)
    }

    @Test func aLineOutOfRangeIsNoFact() {
        #expect(MemoryDocument(text).fact(at: 42) == nil)
        #expect(MemoryDocument("").facts.isEmpty)
    }
}
