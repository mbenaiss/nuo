import Foundation
import Testing

struct MeetingEngineTests {
    @Test func appleUsesTheChosenLanguage() {
        #expect(MeetingLanguage.english.appleLocale(fallback: "fr").identifier == "en-US")
        #expect(MeetingLanguage.french.appleLocale(fallback: "en").identifier == "fr-FR")
    }

    @Test func appleAutoFallsBackToTheDictationLanguage() {
        #expect(MeetingLanguage.auto.appleLocale(fallback: "fr").identifier == "fr-FR")
        #expect(MeetingLanguage.auto.appleLocale(fallback: "en").identifier == "en-US")
        #expect(MeetingLanguage.auto.appleLocale(fallback: "de").identifier == "de")
    }

    @Test func languageNamesAreCapitalizedInTheLocaleOfTheApp() {
        #expect(MeetingLanguage.name(of: "fr", locale: Locale(identifier: "fr_FR")) == "Français")
        #expect(MeetingLanguage.name(of: "en", locale: Locale(identifier: "fr_FR")) == "Anglais")
        #expect(MeetingLanguage.name(of: "fr", locale: Locale(identifier: "en_US")) == "French")
    }

    @Test func everyEngineExplainsItsTradeOff() {
        #expect(MeetingEngine.allCases.map(\.name) == ["Whisper", "Apple"])
        #expect(MeetingEngine.allCases.allSatisfy { $0.detail.contains("MB") })
    }

    @Test func onlyAppleKeepsTheRecordingForAWhisperRetranscription() {
        #expect(MeetingEngine.apple.keepsAudio)
        #expect(!MeetingEngine.whisper.keepsAudio)
    }

    @Test func appleRecordingCanBeRetranscribedOnceTranscribed() {
        var rules = MeetingRecordingRules(kept: true, engine: .apple, transcribed: true, noteReady: false, retranscribing: false)
        #expect(rules.canRetranscribe)
        rules.retranscribing = true
        #expect(!rules.canRetranscribe)
        rules = MeetingRecordingRules(kept: true, engine: .whisper, transcribed: true, noteReady: false, retranscribing: false)
        #expect(!rules.canRetranscribe)
        rules = MeetingRecordingRules(kept: false, engine: .apple, transcribed: true, noteReady: true, retranscribing: false)
        #expect(!rules.canRetranscribe)
    }

    @Test func theAttendeesBoundHowManyVoicesTheOthersHave() {
        #expect(MeetingVoices.plan(participants: "Léa Martin, Hugo Bernard, Alex") == (true, 3))
        #expect(MeetingVoices.plan(participants: "Léa Martin") == (false, nil))
        #expect(MeetingVoices.plan(participants: " ") == (true, nil))
        #expect(MeetingVoices.plan(participants: (1...40).map { "Testeur \($0)" }.joined(separator: ", ")) == (true, 32))
    }

    @Test func voiceSentWithNothingBackIsAFailure() {
        #expect(MeetingVoices.allEmpty([(sentSeconds: 312, segments: 0)]))
        #expect(!MeetingVoices.allEmpty([(sentSeconds: 312, segments: 41)]))
        // A cough or a door on an otherwise silent stream may rightly give nothing.
        #expect(!MeetingVoices.allEmpty([(sentSeconds: 2.5, segments: 0)]))
    }

    @Test func aMicThatOnlyHeardTypingIsTakenAsItIs() {
        #expect(!MeetingVoices.allEmpty([(sentSeconds: 9, segments: 0), (sentSeconds: 1_840, segments: 212)]))
    }

    @Test func onlyEveryStreamComingBackEmptyFailsTheCloud() {
        #expect(MeetingVoices.allEmpty([(sentSeconds: 640, segments: 0), (sentSeconds: 1_840, segments: 0)]))
        // Little voice on every stream: nobody really spoke, the empty answer stands.
        #expect(!MeetingVoices.allEmpty([(sentSeconds: 2, segments: 0), (sentSeconds: 5, segments: 0)]))
        #expect(!MeetingVoices.allEmpty([]))
    }

    @Test func nothingBackWhileOneStreamHadLittleVoiceIsStillEmpty() {
        #expect(MeetingVoices.allEmpty([(sentSeconds: 3, segments: 0), (sentSeconds: 1_840, segments: 0)]))
    }

    @Test func onlyAFailedJobOrNoProviderStopsTheGatewaysJobs() {
        // « Réessayer » cancels a follower while it prepares audio, or while it waits on a job it sent.
        #expect(MeetingCloudLoss.of(CancellationError()) == .none)
        #expect(MeetingCloudLoss.of(TranscriptionJob.Unreachable()) == .none)
        // A file the Mac could not read is its own trouble: the jobs, maybe finished, stay.
        #expect(MeetingCloudLoss.of(CocoaError(.fileReadNoPermission)) == .none)
        #expect(MeetingCloudLoss.of(MeetingStreamFailed(speaker: .them, status: 429, message: "ElevenLabs limite les transcriptions")) == .stream(.them))
        #expect(MeetingCloudLoss.of(MeetingNoTranscriptionService()) == .all)
    }

    @Test func theTitleAndAttendeesAreSpelledRight() {
        #expect(MeetingVoices.terms(title: "Point hebdo Nuo", participants: "Léa Martin, Hugo Bernard") == ["Point hebdo Nuo", "Léa Martin", "Hugo Bernard"])
        #expect(MeetingVoices.terms(title: "", participants: "") == [])
    }

    @Test func recordingCanBeDeletedOnlyOnceTheNoteIsWritten() {
        var rules = MeetingRecordingRules(kept: true, engine: .apple, transcribed: true, noteReady: false, retranscribing: false)
        #expect(!rules.canDelete)
        rules.noteReady = true
        #expect(rules.canDelete)
        rules.retranscribing = true
        #expect(!rules.canDelete)
        rules = MeetingRecordingRules(kept: false, engine: .apple, transcribed: true, noteReady: true, retranscribing: false)
        #expect(!rules.canDelete)
    }
}
