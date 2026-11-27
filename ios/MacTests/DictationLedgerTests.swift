import Testing

struct DictationLedgerTests {
    @Test func aCancelledTranscriptionAnsweringLateNeverLandsInTheNextDictation() {
        var ledger = DictationLedger()
        let first = ledger.begin("composer-coach")
        let result1 = ledger.listen(first)
        #expect(result1)
        let result2 = ledger.finish()
        #expect(result2 == first)
        // ✕ while the gateway is still transcribing, then a new dictation in the same field.
        ledger.cancel()
        let second = ledger.begin("composer-coach")
        let result3 = ledger.listen(second)
        #expect(result3)
        let result4 = ledger.end(first)
        #expect(!result4)
        #expect(ledger.phase == .listening && ledger.key == "composer-coach")
        let result5 = ledger.finish()
        #expect(result5 == second)
        let result6 = ledger.end(second)
        #expect(result6)
        #expect(ledger.phase == .idle && ledger.key == nil)
    }

    @Test func anotherFieldWaitsForTheTranscriptionUnderWay() {
        var ledger = DictationLedger()
        let home = ledger.begin("home-dock")
        _ = ledger.listen(home)
        #expect(ledger.step(for: "composer-coach") == .stopOther)
        _ = ledger.finish()
        #expect(ledger.step(for: "composer-coach") == .waitForOther)
        #expect(ledger.step(for: "home-dock") == .already)
        let result7 = ledger.end(home)
        #expect(result7)
        #expect(ledger.step(for: "composer-coach") == .start)
    }

    @Test func cancelRightAfterSendWinsOverTheTranscription() {
        var ledger = DictationLedger()
        let ticket = ledger.begin("composer-cobot")
        _ = ledger.listen(ticket)
        let result8 = ledger.finish()
        #expect(result8 == ticket)
        ledger.cancel()
        // The answer arrives: it must neither be written nor sent.
        #expect(!ledger.owns(ticket, in: .finishing))
        let result9 = ledger.end(ticket)
        #expect(!result9)
    }

    @Test func aStartCancelledWhileTheMicPermissionIsAskedNeverListens() {
        var ledger = DictationLedger()
        let ticket = ledger.begin("reminder-quick-entry")
        ledger.cancel()
        let result10 = ledger.listen(ticket)
        #expect(!result10)
        let result11 = ledger.finish()
        #expect(result11 == nil)
    }

    @Test func theTextLandsAfterWhatWasTypedMeanwhile() {
        // « Rappelle-moi » was typed while the voice was being transcribed.
        #expect(DictationLedger.compose("Rappelle-moi", "d'appeler Julie Martin demain à 9 h.") == "Rappelle-moi d'appeler Julie Martin demain à 9 h.")
        #expect(DictationLedger.compose("Note : ", "facture EDF à payer.") == "Note : facture EDF à payer.")
        #expect(DictationLedger.compose("", "Peux-tu décaler le kiné à vendredi ?") == "Peux-tu décaler le kiné à vendredi ?")
        #expect(DictationLedger.compose("Brouillon gardé", "") == "Brouillon gardé")
    }
}

struct TranscriptionPollingTests {
    @Test func aDroppedConnectionOrAProxyErrorKeepsWaiting() {
        #expect(TranscriptionPolling.isTransient(.unreachable))
        #expect(TranscriptionPolling.isTransient(.server(status: 502, message: "")))
    }

    @Test func aBusyGatewayIsNoFailureOfANamedJob() {
        #expect(TranscriptionPolling.isBusy(.server(status: 429, message: "trop de transcriptions en cours, attends la fin de la précédente")))
        #expect(!TranscriptionPolling.isBusy(.server(status: 502, message: "clé ElevenLabs refusée")))
        #expect(!TranscriptionPolling.isBusy(.unknownJob))
    }

    @Test func theJobsOwnErrorOrAForgottenJobEndsTheWait() {
        #expect(!TranscriptionPolling.isTransient(.unknownJob))
        #expect(!TranscriptionPolling.isTransient(.server(status: 502, message: "clé ElevenLabs (NUO_ELEVENLABS_API_KEY) refusée")))
        #expect(!TranscriptionPolling.isTransient(.server(status: 429, message: "")))
        #expect(!TranscriptionPolling.isTransient(.other))
    }
}
