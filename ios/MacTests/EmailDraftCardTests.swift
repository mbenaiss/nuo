import Foundation
import Testing

struct EmailDraftCardTests {
    private let quote = EmailDraftPayload(
        account: "alex@lumen.example", draftId: "r-5829163047",
        to: ["Julie Martin <julie.martin@lumen.example>"], cc: ["compta@lumen.example"], bcc: [],
        subject: "Devis cuisine, version 2",
        body: "Bonjour Julie,\n\nVoici le devis revu : 4 280 € TTC.\n\nAlex")

    @Test func theGatewaysLineBecomesAnEmailCard() {
        let text = """
        Le brouillon est prêt, rien n'est parti.
        ::email {"account":"alex@lumen.example","draftId":"r-5829163047","to":["Julie Martin <julie.martin@lumen.example>"],"cc":["compta@lumen.example"],"bcc":[],"subject":"Devis cuisine, version 2","body":"Bonjour Julie,\\n\\nVoici le devis revu : 4 280 € TTC.\\n\\nAlex"}
        """
        #expect(ResponseBlockParser.parse(text) == [
            .paragraph("Le brouillon est prêt, rien n'est parti."),
            .email(quote),
        ])
        #expect(ResponseBlockParser.plainText(text) == "Le brouillon est prêt, rien n'est parti.")
    }

    @Test func recipientsWrittenAsOneLineAreSplitWithoutBreakingAQuotedName() {
        let line = #"::email {"draftId":"r-5829163047","to":"\"Martin, Julie\" <julie.martin@lumen.example>; compta@lumen.example","subject":"Devis cuisine, version 2","body":"Bonjour Julie"}"#
        guard case let .email(draft)? = ResponseBlockParser.parse(line).first else {
            Issue.record("expected an email card")
            return
        }
        #expect(draft.to == [#""Martin, Julie" <julie.martin@lumen.example>"#, "compta@lumen.example"])
        #expect(draft.cc.isEmpty && draft.bcc.isEmpty)
        #expect(draft.account.isEmpty)
    }

    @Test func aLineWithoutDraftIdStaysText() {
        let line = #"::email {"to":["julie.martin@lumen.example"],"subject":"Devis cuisine, version 2","body":"Bonjour Julie"}"#
        #expect(ResponseBlockParser.parse(line) == [.paragraph(line)])
    }

    @Test func theGatewaysDraftDecodes() throws {
        let draft = try JSONDecoder().decode(EmailDraftPayload.self, from: Data("""
        {"account":"alex@lumen.example","draftId":"r-5829163047","to":["Julie Martin <julie.martin@lumen.example>"],
         "cc":["compta@lumen.example"],"bcc":[],"subject":"Devis cuisine, version 2",
         "body":"Bonjour Julie,\\n\\nVoici le devis revu : 4 280 € TTC.\\n\\nAlex"}
        """.utf8))
        #expect(draft == quote)
    }

    @Test func theFormSavesEveryFieldAndIgnoresSpacingAroundCommas() throws {
        var form = EmailDraftForm(quote)
        #expect(form.to == "Julie Martin <julie.martin@lumen.example>")
        #expect(!form.differs(from: quote))

        form.cc = "  compta@lumen.example ,"
        #expect(!form.differs(from: quote))

        form.subject = "Devis cuisine, version 3 "
        form.bcc = "archives@lumen.example"
        #expect(form.differs(from: quote))
        #expect(form.update == EmailDraftUpdate(
            to: ["Julie Martin <julie.martin@lumen.example>"], cc: ["compta@lumen.example"], bcc: ["archives@lumen.example"],
            subject: "Devis cuisine, version 3", body: quote.body))

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(form.update)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["to", "cc", "bcc", "subject", "body"])
    }

    @Test func aDraftWithoutRecipientCannotBeSent() {
        var form = EmailDraftForm(quote)
        #expect(form.problem == nil)
        form.to = " , "
        #expect(form.problem == "Add at least one recipient.")
    }

    @Test func theConfirmationNamesTheFirstAddressAndCountsTheOthers() {
        let one = EmailDraftUpdate(to: ["Julie Martin <julie.martin@lumen.example>"], cc: [], bcc: [], subject: "Devis cuisine, version 2", body: "")
        #expect(EmailDraftText.sendPrompt(one) == "Send to julie.martin@lumen.example?")
        #expect(EmailDraftText.sendPrompt(EmailDraftForm(quote).update) == "Send to julie.martin@lumen.example and 1 other recipient?")
        var three = one
        three.cc = ["compta@lumen.example"]
        three.bcc = ["archives@lumen.example"]
        #expect(EmailDraftText.sendPrompt(three) == "Send to julie.martin@lumen.example and 2 other recipients?")
        #expect(EmailDraftText.address("compta@lumen.example") == "compta@lumen.example")
    }
}
