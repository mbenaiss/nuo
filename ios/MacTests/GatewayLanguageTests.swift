import Foundation
import Testing

struct GatewayLanguageTests {
    @Test func listsTheUserLanguagesByDecreasingWeight() {
        #expect(GatewayLanguage.acceptLanguage(["fr-FR", "en-US", "es-ES"]) == "fr-FR, en-US;q=0.9, es-ES;q=0.8")
    }

    @Test func keepsFiveLanguagesAtMost() {
        let header = GatewayLanguage.acceptLanguage(["de-DE", "fr-FR", "en-GB", "it-IT", "nl-NL", "pt-PT"])
        #expect(header == "de-DE, fr-FR;q=0.9, en-GB;q=0.8, it-IT;q=0.7, nl-NL;q=0.6")
    }

    @Test func sendsNothingWithoutALanguage() {
        #expect(GatewayLanguage.acceptLanguage([]) == nil)
    }
}
