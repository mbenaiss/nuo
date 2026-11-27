import Foundation
import Testing

struct ToolTagTests {
    /// The regexes the scanners replaced: the scanners must answer the same on every text.
    private func regexQuery(_ text: String) -> String? {
        text.firstMatch(of: /(?:^|\s)#([A-Za-z0-9_\-]*)$/).map { String($0.1).lowercased() }
    }

    private func regexTags(_ text: String) -> [String] {
        text.matches(of: /(?:^|\s)#([a-z0-9_\-]+)/).map { String($0.1) }
    }

    private let texts = [
        "", "#", "#gh", "#GH", "#gh-cli_2", "Vérifie #prox", "Vérifie#prox", "Vérifie #prox mox", "#proxmox\n",
        "Déploie la passerelle\n#dock", "Déploie la passerelle\t#", "#gh #docker", "##gh", "#gh#docker", "#gh!", "#é",
        "ligne 1\r\n#homeassistant", "a #gh b #DOCKER c #rclone-sync", "Coût #1 et #2", "e\u{301}#gh", " \u{00A0}#gh",
    ]

    @Test func findsTheTagBeingTypedLikeTheRegex() {
        for text in texts {
            #expect(ToolTag.query(in: text) == regexQuery(text), "\(text.debugDescription)")
        }
    }

    @Test func findsTheTagsOfAMessageLikeTheRegex() {
        for text in texts {
            #expect(ToolTag.tags(in: text).map(\.id) == regexTags(text), "\(text.debugDescription)")
        }
    }

    @Test func rangesCoverTheHashAndTheId() {
        let text = "Relance #docker puis #gh"
        #expect(ToolTag.tags(in: text).map { String(text[$0.range]) } == ["#docker", "#gh"])
    }

    @Test func splitsLeadingTagsFromTheMessage() {
        let parsed = ToolTag.parse("#proxmox #docker redémarre la VM 104", known: ["proxmox", "docker"])
        #expect(parsed?.leading == ["proxmox", "docker"])
        #expect(parsed?.rest == "redémarre la VM 104")
        #expect(ToolTag.parse("Commande ORD-2026-104857 #urgent", known: ["proxmox"]) == nil)
        #expect(ToolTag.parse("Redémarre la VM 104 avec #proxmox", known: ["proxmox"])?.leading == [])
    }

    /// A pasted log of 400 000 characters froze the Mac composer for seconds on every keystroke.
    @Test func answersAtOnceOnAVeryLongPastedText() {
        let line = "2026-10-31T09:14:02.381Z [gateway] prompt conv=c-voyages-1 bot=voyages tokens=48213 #deploy\n"
        let text = String(repeating: line, count: 5_000) + "Regarde ce log avec #gh"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<100 { _ = ToolTag.query(in: text) }
        }
        #expect(ToolTag.query(in: text) == "gh")
        #expect(elapsed < .milliseconds(50))
    }
}
