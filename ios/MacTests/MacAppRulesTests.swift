import Foundation
import Testing

struct MacLinkOverrideTests {
    @Test func dataWithoutCollectionOpensCollections() {
        #expect(MacLinkOverride(url: URL(string: "nuo://data")!) == .collections)
        #expect(MacLinkOverride(url: URL(string: "nuo://data/")!) == .collections)
    }

    @Test func linksTheSharedRoutersHandleAreLeftToThem() {
        #expect(MacLinkOverride(url: URL(string: "nuo://data/factures")!) == nil)
        #expect(MacLinkOverride(url: URL(string: "nuo://data/factures/fac-2026-0412")!) == nil)
        #expect(MacLinkOverride(url: URL(string: "nuo://docs/projets/renovation-cuisine")!) == nil)
        #expect(MacLinkOverride(url: URL(string: "nuo://bot/voyages/voice")!) == nil)
        #expect(MacLinkOverride(url: URL(string: "https://nuo.example.com/data")!) == nil)
    }
}

struct QuitPromptTests {
    @Test func nothingPendingQuitsWithoutAsking() {
        #expect(QuitPrompt.message(for: []) == nil)
        #expect(QuitPrompt.message(for: ["  "]) == nil)
    }

    @Test func singleReasonIsShownAsIs() {
        let reason = "La réunion « Point hebdo produit » est en cours de transcription."
        #expect(QuitPrompt.message(for: [reason]) == reason)
    }

    @Test func severalReasonsAreListed() {
        let message = QuitPrompt.message(for: [
            "La réunion « Point hebdo produit » est en cours de transcription.",
            "Le document « Compte rendu comité 14 octobre » n'est pas encore enregistré.",
        ])
        #expect(message == """
        • La réunion « Point hebdo produit » est en cours de transcription.
        • Le document « Compte rendu comité 14 octobre » n'est pas encore enregistré.
        """)
    }
}
