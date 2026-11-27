import Foundation
import Testing

struct MeetingTranscriptTests {
    @Test func segmentsArrivingOutOfOrderAreSortedBySpeech() {
        var transcript = MeetingTranscript()
        transcript.insert("Je m'occupe de la note de version.", speaker: .me, start: 58, end: 61)
        transcript.insert("On peut viser le vendredi 24.", speaker: .them, start: 44, end: 47)
        transcript.insert("Salut, on commence ?", speaker: .them, start: 4, end: 6)
        #expect(transcript.segments.map(\.start) == [4, 44, 58])
    }

    @Test func hesitationsNeverReachTheTranscript() {
        var transcript = MeetingTranscript()
        transcript.insert("Euh, salut, on commence ?", speaker: .them, start: 4, end: 6)
        transcript.insert("Hum.", speaker: .me, start: 8, end: 9)
        #expect(transcript.segments.map(\.text) == ["Salut, on commence ?"])
    }

    @Test func theOthersVoicesSplitTheirTurnsAndNameThem() {
        var transcript = MeetingTranscript()
        transcript.insert("On peut viser le vendredi 24.", speaker: .them, start: 44, end: 47, voice: "1")
        transcript.insert("Hugo, tu prépares la liste des testeurs ?", speaker: .them, start: 47.5, end: 50, voice: "1")
        transcript.insert("Oui, je l'envoie mardi soir.", speaker: .them, start: 52, end: 54, voice: "2")
        transcript.insert("Parfait, merci à vous deux.", speaker: .me, start: 56, end: 58, voice: "3")
        #expect(transcript.voiceCount == 2)
        #expect(transcript.turns.map(\.voice) == ["1", "2", nil])
        #expect(transcript.plainText(meName: "Alex") == """
            [00:44] Eux · voix 1 : On peut viser le vendredi 24. Hugo, tu prépares la liste des testeurs ?
            [00:52] Eux · voix 2 : Oui, je l'envoie mardi soir.
            [00:56] Alex : Parfait, merci à vous deux.
            """)
    }

    @Test func aSingleVoiceStaysEux() {
        var transcript = MeetingTranscript()
        transcript.insert("Ça me va. On en reparle lundi.", speaker: .them, start: 838, end: 841, voice: "1")
        #expect(transcript.plainText(meName: "Moi") == "[13:58] Eux : Ça me va. On en reparle lundi.")
    }

    @Test func cloudLinesComeBackOnTheMeetingsClock() {
        // Two voiced stretches were sent: 2 s from 30 s into the stream, then 3 s from 90 s, with 0.3 s between them.
        let map = MeetingSpeech.Compacted(samples: [], pieces: [
            .init(at: 0, source: 30 * 16_000, count: 2 * 16_000),
            .init(at: 2 * 16_000 + 4_800, source: 90 * 16_000, count: 3 * 16_000),
        ])
        var transcript = MeetingTranscript()
        transcript.insert(cloud: [
            .init(start: 0.1, end: 1.9, text: "Euh, salut, on commence ?", speaker: "1"),
            .init(start: 2.4, end: 5.2, text: "Dernier point : on ouvre la bêta ?", speaker: "2"),
        ], speaker: .them, map: map, startOffset: 1.5)
        #expect(transcript.segments.map(\.text) == ["Salut, on commence ?", "Dernier point : on ouvre la bêta ?"])
        #expect(abs(transcript.segments[0].start - 31.6) < 0.01)
        #expect(abs(transcript.segments[1].start - 91.6) < 0.01)
        #expect(abs(transcript.segments[1].end - 94.4) < 0.01)
        #expect(transcript.segments.map(\.voice) == ["1", "2"])
    }

    @Test func anEchoOfALongLineIsStillFound() {
        var transcript = MeetingTranscript()
        // A long line of the others (a monologue the service did not split), and the mic's echo of its last words.
        transcript.insert("On garde la date du vendredi 24 pour la bêta et on prévient les testeurs mercredi.", speaker: .them, start: 0, end: 200)
        transcript.insert("On garde la date du vendredi 24 pour la bêta.", speaker: .me, start: 195, end: 198)
        #expect(transcript.segments.map(\.speaker) == [.them])
    }

    @Test func aTwoHourMeetingIsAssembledQuickly() {
        var transcript = MeetingTranscript()
        let clock = ContinuousClock.now
        // A line every 4 s on each side for two hours, the others' arriving after the user's, and each with a mic echo.
        for index in 0..<1_800 {
            let at = TimeInterval(index * 4)
            transcript.insert("Point \(index) : on garde la date du vendredi pour la bêta avec Léa.", speaker: .them, start: at, end: at + 3)
            transcript.insert("Point \(index) : on garde la date du vendredi pour la bêta avec Léa.", speaker: .me, start: at + 1, end: at + 4)
            transcript.insert("Réponse \(index) : d'accord, je préviens Hugo ce soir.", speaker: .me, start: at + 2, end: at + 3.5)
        }
        let elapsed = ContinuousClock.now - clock
        print("Echo pass: \(transcript.segments.count) segments in \(elapsed)")
        #expect(transcript.segments.count == 3_600)
        #expect(!transcript.segments.contains { $0.speaker == .me && $0.text.hasPrefix("Point") })
        #expect(elapsed < .seconds(3))
    }

    @Test func turnsJoinOneSpeakerUntilALongPause() {
        var transcript = MeetingTranscript()
        transcript.insert("Côté design, les maquettes sont prêtes.", speaker: .them, start: 22, end: 25)
        transcript.insert("Je te les envoie ce soir.", speaker: .them, start: 26, end: 28)
        transcript.insert("Super, merci Léa.", speaker: .me, start: 30, end: 31)
        transcript.insert("Il faudrait caler la date de la bêta.", speaker: .me, start: 35, end: 38)
        transcript.insert("Dernier point : on ouvre la bêta à plus de monde ?", speaker: .them, start: 612, end: 616)
        transcript.insert("Ça me va, on en reparle lundi.", speaker: .them, start: 838, end: 841)
        let turns = transcript.turns
        #expect(turns.map(\.speaker) == [.them, .me, .them, .them])
        #expect(turns[0].text == "Côté design, les maquettes sont prêtes. Je te les envoie ce soir.")
        #expect(turns[1].start == 30 && turns[1].end == 38)
    }

    @Test func micEchoOfTheOtherSideIsDropped() {
        var transcript = MeetingTranscript()
        transcript.insert("On peut viser le vendredi 24 pour la bêta.", speaker: .them, start: 44, end: 48)
        // Without headphones the mic hears the speakers a moment later.
        transcript.insert("on peut viser le vendredi 24 pour la bêta", speaker: .me, start: 44.4, end: 48.2)
        #expect(transcript.segments.map(\.speaker) == [.them])
    }

    @Test func echoArrivingFirstIsRemovedWhenTheOtherSideCatchesUp() {
        var transcript = MeetingTranscript()
        transcript.insert("Hugo, tu prépares la liste des testeurs ?", speaker: .me, start: 50.3, end: 53)
        transcript.insert("Hugo, tu prépares la liste des testeurs d'ici mercredi ?", speaker: .them, start: 50, end: 54)
        #expect(transcript.segments.map(\.speaker) == [.them])
    }

    @Test func aShortReplyOverTheOtherSideIsKept() {
        var transcript = MeetingTranscript()
        transcript.insert("On part sur vendredi, d'accord ?", speaker: .them, start: 60, end: 62)
        transcript.insert("Oui, d'accord.", speaker: .me, start: 61, end: 62)
        transcript.insert("Je préfère rester sur une trentaine de testeurs.", speaker: .me, start: 63, end: 66)
        #expect(transcript.segments.map(\.speaker) == [.them, .me, .me])
    }

    @Test func emptyTextIsIgnored() {
        var transcript = MeetingTranscript()
        transcript.insert("   \n", speaker: .them, start: 3, end: 4)
        #expect(transcript.isEmpty)
    }

    @Test func plainTextNamesTheUser() {
        var transcript = MeetingTranscript()
        transcript.insert("Salut, on commence ?", speaker: .them, start: 4, end: 6)
        transcript.insert("Oui, les rappels sont synchronisés.", speaker: .me, start: 11, end: 14)
        #expect(transcript.plainText(meName: "Alex") == "[00:04] Eux : Salut, on commence ?\n[00:11] Alex : Oui, les rappels sont synchronisés.")
        #expect(transcript.wordCount == 9)
    }
}
