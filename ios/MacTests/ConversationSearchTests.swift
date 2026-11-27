import Foundation
import Testing

struct ConversationSearchTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Wire.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return decoder
    }

    @Test func readsAHitFoundInAMessageAndOneFoundByItsTitle() throws {
        let hits = try decoder().decode([ConversationSearchHit].self, from: Data("""
        [
          {"conversation":{"id":"c-contrat","botId":"b-maison","title":"Contrat d'électricité","useDraft":false,
            "createdAt":"2026-11-03T09:02:00.000Z","updatedAt":"2026-11-03T09:03:00.000Z"},
           "messageId":"m-facture","role":"assistant","snippet":"…Ta facture EDF de février s'élève à 142,30 €…"},
          {"conversation":{"id":"c-lisbonne","botId":"b-voyages","title":"Lisbonne en mars","useDraft":true,
            "createdAt":"2026-11-03T09:00:00.000Z","updatedAt":"2026-11-03T09:01:00.000Z"}}
        ]
        """.utf8))
        #expect(hits.map(\.id) == ["c-contrat", "c-lisbonne"])
        #expect(hits[0].role == .assistant)
        #expect(hits[0].snippet?.contains("facture EDF") == true)
        #expect(hits[1].snippet == nil && hits[1].conversation.useDraft)
    }

    @Test func matchesEveryWordWithoutCaseOrAccents() {
        let terms = ConversationSearchText.terms("  Électricité, FACTURE ")
        #expect(terms == ["electricite", "facture"])
        #expect(ConversationSearchText.matches("Ta facture d'électricité de février", terms))
        #expect(!ConversationSearchText.matches("Ta facture de gaz de février", terms))
        #expect(!ConversationSearchText.matches("Ta facture d'électricité", []))
    }

    @Test func cutsALongMessageAroundTheWordFoundOnOneLine() {
        let message = String(repeating: "Le vol part de CDG. ", count: 10) + "\nLa réservation TP439 est confirmée.\n" + String(repeating: "Bagage cabine inclus. ", count: 10)
        let excerpt = ConversationSearchText.excerpt(message, around: ["tp439"], radius: 30)
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
        #expect(excerpt.contains("La réservation TP439 est confirmée."))
        #expect(!excerpt.contains("\n"))
        #expect(ConversationSearchText.excerpt("Vol confirmé.", around: ["tp439"]) == "Vol confirmé.")
    }

    @Test func aConversationCardNamesTheConversationAndItsBot() {
        let text = """
        J'ai retrouvé la discussion sur ton contrat :
        ::conversation {"id":"c-contrat","botId":"b-maison","title":"Contrat d'électricité"}
        """
        #expect(ResponseBlockParser.parse(text) == [
            .paragraph("J'ai retrouvé la discussion sur ton contrat :"),
            .conversation(ConversationLinkPayload(id: "c-contrat", botId: "b-maison", title: "Contrat d'électricité")),
        ])
        #expect(ResponseBlockParser.parse(#"::conversation {"title":"Sans identifiant"}"#) == [.paragraph(#"::conversation {"title":"Sans identifiant"}"#)])
    }

    @Test func theOverviewSettingIsOffUnlessTheGatewaySaysSo() throws {
        let json = ##"{"name":"Général","emoji":"🧭","color":"#E0EEFF","description":"Point d'entrée","agent":"claude","model":"claude-sonnet-4-5","instructions":"Tu vois tous les bots.","toolServers":[],"permissionPolicy":"ask""##
        let on = try JSONDecoder().decode(BotConfig.self, from: Data((json + #","overview":true}"#).utf8))
        let off = try JSONDecoder().decode(BotConfig.self, from: Data((json + "}").utf8))
        #expect(on.overview == true && off.overview == nil)
    }
}
